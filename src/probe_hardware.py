#!/usr/bin/env python3
"""
probe_hardware.py - Deteccion de GPU y recomendacion de perfil para ComfyUI.

Emite un unico objeto JSON por stdout. No asume ningun fabricante, modelo ni
cantidad de VRAM: si un dato no se puede determinar se reporta como null y
quien consuma el JSON decide que hacer. Nunca inventa valores por defecto.
"""

import json
import re
import shutil
import subprocess
import sys

# Objetivos de PyTorch soportados. Solo los que pyproject.toml declara como
# extras y uv.lock fija: recomendar uno fuera de esta lista produciria una
# instalacion no reproducible. Una version fuera del mapa se rechaza en lugar
# de caer silenciosamente a otra.
CUDA_WHEEL_INDEXES = {
    "12.6": "https://download.pytorch.org/whl/cu126",
    "13.0": "https://download.pytorch.org/whl/cu130",
}
CPU_WHEEL_INDEX = "https://download.pytorch.org/whl/cpu"

# Capacidad de computo -> nombre de arquitectura.
COMPUTE_ARCH = {
    "6.1": "Pascal",
    "7.0": "Volta",
    "7.5": "Turing",
    "8.0": "Ampere",
    "8.6": "Ampere",
    "8.7": "Ampere",
    "8.9": "Ada Lovelace",
    "9.0": "Hopper",
    "10.0": "Blackwell",
    "12.0": "Blackwell",
}

# Registro de aceleradores: unica fuente de verdad del proyecto.
#
# Anadir uno solo requiere una fila aqui y un extra en pyproject.toml. El resto
# del gestor (probe, setup, upgrade, doctor y start) consume esta tabla a
# traves del JSON que emite este script, en vez de comprobar nombres propios
# repartidos por los modulos.
#
#   key          nombre en etc/config.json
#   extra        extra de pyproject.toml que instala el paquete
#   package      nombre de distribucion (solo informativo, para mensajes)
#   module       modulo a importar para comprobar que funciona
#   runtime_flag argumento que hay que pasarle a main.py, o None
#   min_compute  capacidad de computo minima
#   windows_only si la rueda existe unicamente para Windows
ACCELERATORS = [
    {
        "key": "triton",
        "extra": "triton",
        "package": "triton-windows",
        "module": "triton",
        "runtime_flag": None,
        "min_compute": 7.0,        # compila kernels desde Volta
        "windows_only": True,
    },
    {
        "key": "sage_attention",
        "extra": "sage",
        "package": "sageattention",
        "module": "sageattention",
        "runtime_flag": "--use-sage-attention",
        "min_compute": 8.0,        # la cuantizacion INT8 requiere sm_80
        "windows_only": False,
    },
]

# Campos del registro que se propagan al JSON y a etc/config.json.
_ACCEL_FIELDS = ("key", "extra", "package", "module", "runtime_flag", "min_compute")


def evaluate_accelerators(vendor, compute, platform=None):
    """
    Decide que aceleradores aplican, con el motivo de cada decision.

    Cada entrada se evalua de forma independiente: antes, un unico bloque
    condicional apagaba Triton junto con SageAttention, de modo que una GPU
    Volta (sm_7.0) se quedaba sin Triton pese a superar su propio umbral.
    """
    if platform is None:
        platform = sys.platform

    result = []
    for accel in ACCELERATORS:
        entry = {field: accel[field] for field in _ACCEL_FIELDS}

        if vendor != "NVIDIA":
            enabled, reason = False, "requiere una GPU NVIDIA"
        elif accel["windows_only"] and platform != "win32":
            enabled, reason = False, "solo hay ruedas para Windows"
        elif compute is None:
            enabled, reason = False, "capacidad de computo desconocida"
        elif compute < accel["min_compute"]:
            enabled, reason = (
                False,
                "requiere sm_%s y la GPU es sm_%s" % (accel["min_compute"], compute),
            )
        else:
            enabled, reason = (
                True,
                "sm_%s cumple el minimo sm_%s" % (compute, accel["min_compute"]),
            )

        entry["enabled"] = enabled
        entry["reason"] = reason
        result.append(entry)

    return result

# Umbral de VRAM (GB) para activar --lowvram por defecto.
LOWVRAM_MAX_GB = 6.0


def _run(cmd, timeout=20):
    """Ejecuta un comando y devuelve stdout, o None si falla."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    out = result.stdout.strip()
    return out or None


def detect_via_nvidia_smi():
    """
    Consulta nvidia-smi. Intenta primero con compute_cap (driver moderno) y
    reintenta sin ese campo: los drivers antiguos no lo soportan y rechazan la
    consulta entera, con lo que sin reintento se perderia la GPU por completo.
    """
    if not shutil.which("nvidia-smi"):
        return None

    attempts = [
        (["gpu_name", "memory.total", "driver_version", "compute_cap"], True),
        (["gpu_name", "memory.total", "driver_version"], False),
    ]

    for fields, has_compute in attempts:
        out = _run([
            "nvidia-smi",
            "--query-gpu=" + ",".join(fields),
            "--format=csv,noheader,nounits",
        ])
        if not out:
            continue

        gpus = []
        for line in out.splitlines():
            if not line.strip():
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 2:
                continue

            try:
                vram_gb = round(float(parts[1]) / 1024, 1)
            except ValueError:
                vram_gb = None

            compute = None
            if has_compute and len(parts) > 3 and re.fullmatch(r"\d+\.\d+", parts[3]):
                compute = parts[3]

            gpus.append({
                "vendor": "NVIDIA",
                "model": parts[0],
                "vram_gb": vram_gb,
                "compute": compute,
                "driver": parts[2] if len(parts) > 2 else None,
                "source": "nvidia-smi",
            })

        if gpus:
            gpus.sort(key=lambda g: g["vram_gb"] or 0, reverse=True)
            return gpus[0]

    return None


def detect_via_wmi():
    """
    Enumera adaptadores de video via CIM. Solo aporta fabricante y modelo:
    AdapterRAM es un uint32 que se desborda por encima de 4 GB, asi que la
    VRAM que reporta NO es fiable y se descarta deliberadamente.
    """
    if sys.platform != "win32":
        return None

    ps_cmd = (
        "Get-CimInstance Win32_VideoController | "
        "Select-Object Name, DriverVersion | "
        "ConvertTo-Json -Compress"
    )

    for shell in ("pwsh", "powershell"):
        if not shutil.which(shell):
            continue
        out = _run([shell, "-NoProfile", "-NonInteractive", "-Command", ps_cmd])
        if not out:
            continue
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict):
            data = [data]

        gpus = []
        for item in data:
            name = (item.get("Name") or "").strip()
            if not name:
                continue
            upper = name.upper()
            if any(k in upper for k in ("NVIDIA", "GEFORCE", "RTX", "GTX", "QUADRO", "TESLA")):
                vendor = "NVIDIA"
            elif any(k in upper for k in ("AMD", "RADEON", "FIREPRO")):
                vendor = "AMD"
            elif any(k in upper for k in ("INTEL", "ARC", "IRIS")):
                vendor = "INTEL"
            else:
                vendor = "UNKNOWN"

            gpus.append({
                "vendor": vendor,
                "model": name,
                "vram_gb": None,          # No fiable via WMI.
                "compute": None,
                "driver": (item.get("DriverVersion") or "").strip() or None,
                "source": "wmi",
            })

        if gpus:
            rank = {"NVIDIA": 0, "AMD": 1, "INTEL": 2, "UNKNOWN": 3}
            gpus.sort(key=lambda g: rank.get(g["vendor"], 9))
            return gpus[0]

    return None


def pick_cuda_version(compute):
    """
    Elige la version de CUDA segun la capacidad de computo.

    Desde sm_75 (serie 20) se apunta a CUDA 13.0 porque comfy_kitchen, que
    ComfyUI trae en sus requirements, deshabilita sus backends 'cuda' y
    'triton' si PyTorch se compilo contra una version anterior: con cu126 los
    reporta como available=True, disabled=True y se pierden los kernels
    optimizados. CUDA 13 ya no soporta Pascal y anteriores (sm < 7.5), que se
    quedan en la rama 12.x.
    """
    if compute is None:
        # Sin capacidad conocida, el objetivo que cubre de Pascal en adelante.
        return "12.6"
    if compute >= 7.5:
        return "13.0"
    return "12.6"


def build_recommendation(gpu):
    vendor = gpu.get("vendor") or "UNKNOWN"
    model = gpu.get("model") or "Desconocido"
    vram_gb = gpu.get("vram_gb")
    compute_str = gpu.get("compute")

    compute = None
    if compute_str:
        try:
            compute = float(compute_str)
        except (TypeError, ValueError):
            compute = None

    arch = COMPUTE_ARCH.get(compute_str) if compute_str else None

    rec = {
        "vendor": vendor,
        "model": model,
        "vram_gb": vram_gb,
        "arch": arch,
        "cuda_compute": compute_str,
        "driver": gpu.get("driver"),
        "detection_source": gpu.get("source", "none"),
        "accelerator": "cpu",
        "cuda_version": None,
        "torch_index_url": CPU_WHEEL_INDEX,
        "accelerators": evaluate_accelerators(vendor, compute),
        "lowvram": False,
        "highvram": False,
        "preview_method": "auto",
        "profile": "cpu-only",
        "supported": False,
        "warnings": [],
        "summary": "",
    }

    if vendor == "NVIDIA":
        rec["accelerator"] = "cuda"
        rec["supported"] = True

        cuda_version = pick_cuda_version(compute)
        rec["cuda_version"] = cuda_version
        rec["torch_index_url"] = CUDA_WHEEL_INDEXES[cuda_version]

        if compute is None:
            rec["warnings"].append(
                "No se pudo determinar la capacidad de computo (driver antiguo o "
                "nvidia-smi ausente). Se asume un objetivo conservador (CUDA 12.6) "
                "y se desactivan los aceleradores. Forzalo con: setup --cuda <version>."
            )
        elif compute < 7.5:
            rec["warnings"].append(
                "GPU anterior a la serie 20 (sm_" + str(compute_str) + "). CUDA 13 no "
                "la soporta, asi que los backends optimizados de comfy_kitchen "
                "quedaran deshabilitados."
            )

        for accel in rec["accelerators"]:
            if not accel["enabled"] and compute is not None:
                rec["warnings"].append(
                    "%s no se instalara: %s." % (accel["package"], accel["reason"])
                )

        if vram_gb is None:
            rec["warnings"].append(
                "No se pudo determinar la VRAM. Se usa el modo normal; si aparecen "
                "errores de memoria ejecuta: start --lowvram"
            )
            vram_label = "VRAM desconocida"
        else:
            if vram_gb < LOWVRAM_MAX_GB:
                rec["lowvram"] = True
            vram_label = str(vram_gb) + " GB"

        vram_slug = (str(int(vram_gb)) + "gb") if vram_gb else "unknown"
        parts = ["nvidia"]
        if arch:
            parts.append(arch.lower().replace(" ", ""))
        parts.append(vram_slug)
        rec["profile"] = "-".join(parts)

        enabled = [a["package"] for a in rec["accelerators"] if a["enabled"]]
        accel_label = ", ".join(enabled) if enabled else "sin aceleradores adicionales"

        rec["summary"] = (
            model + " (" + vram_label
            + ((", " + arch) if arch else "") + "). "
            + "PyTorch CUDA " + cuda_version + ", " + accel_label + ". "
            + "Modo de memoria por defecto: "
            + ("lowvram" if rec["lowvram"] else "normal") + "."
        )

    elif vendor in ("AMD", "INTEL"):
        rec["profile"] = "amd-unsupported" if vendor == "AMD" else "intel-unsupported"
        alt = "ROCm (Linux) o DirectML/ZLUDA" if vendor == "AMD" else "IPEX o DirectML"
        rec["warnings"].append(
            "Este gestor solo automatiza la ruta CUDA. Para " + vendor
            + " necesitas " + alt + ", que debes configurar manualmente."
        )
        rec["summary"] = (
            model + ": GPU " + vendor + " detectada. No hay ruta acelerada "
            "automatica; la instalacion usaria PyTorch CPU, muy lento para difusion."
        )

    else:
        rec["warnings"].append(
            "No se detecto GPU dedicada. PyTorch CPU funciona pero es muy lento."
        )
        rec["summary"] = (
            "No se detecto GPU compatible. Se configuraria PyTorch en modo CPU."
        )

    return rec


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--accelerators":
        vendor = argv[1] if len(argv) > 1 and argv[1] else "UNKNOWN"
        compute = None
        if len(argv) > 2 and argv[2]:
            try:
                compute = float(argv[2])
            except ValueError:
                compute = None
        print(json.dumps(evaluate_accelerators(vendor, compute), indent=2))
        return

    gpu = detect_via_nvidia_smi() or detect_via_wmi()

    if gpu is None:
        gpu = {
            "vendor": "NONE",
            "model": None,
            "vram_gb": None,
            "compute": None,
            "driver": None,
            "source": "none",
        }

    print(json.dumps(build_recommendation(gpu), indent=2))


if __name__ == "__main__":
    main()
