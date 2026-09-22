"""Pruebas de la matriz de decision de src/probe_hardware.py."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import probe_hardware as ph  # noqa: E402


def gpu(vendor="NVIDIA", model="GPU", vram_gb=12.0, compute="8.6", source="nvidia-smi"):
    return {
        "vendor": vendor,
        "model": model,
        "vram_gb": vram_gb,
        "compute": compute,
        "driver": None,
        "source": source,
    }


class TestPickCudaVersion:
    # Desde sm_75, comfy_kitchen deshabilita su backend 'cuda' si PyTorch se
    # compilo contra una version anterior a 13.0.
    @pytest.mark.parametrize("compute", [7.5, 8.6, 8.9, 9.0, 10.0, 12.0])
    def test_serie_20_en_adelante_usa_cuda_13(self, compute):
        assert ph.pick_cuda_version(compute) == "13.0"

    # CUDA 13 ya no soporta Pascal y anteriores.
    @pytest.mark.parametrize("compute", [6.1, 7.0])
    def test_pre_turing_se_queda_en_12_6(self, compute):
        assert ph.pick_cuda_version(compute) == "12.6"

    def test_sin_dato_elige_el_objetivo_conservador(self):
        assert ph.pick_cuda_version(None) == "12.6"

    def test_todo_objetivo_existe_en_el_mapa_de_indices(self):
        for compute in (None, 6.1, 7.5, 8.6, 12.0):
            assert ph.pick_cuda_version(compute) in ph.CUDA_WHEEL_INDEXES


class TestAceleradores:
    def test_sage_requiere_sm80(self):
        rec = ph.build_recommendation(gpu(compute="7.5"))
        assert rec["triton"] is True
        assert rec["sage_attention"] is False
        assert any("sm_80" in w for w in rec["warnings"])

    def test_ampere_habilita_ambos(self):
        rec = ph.build_recommendation(gpu(compute="8.6"))
        assert rec["triton"] is True
        assert rec["sage_attention"] is True
        assert rec["warnings"] == []

    # Sin capacidad de computo no se puede garantizar nada: se desactivan y
    # se avisa, en vez de asumir que funcionaran.
    def test_sin_compute_desactiva_aceleradores_y_avisa(self):
        rec = ph.build_recommendation(gpu(compute=None))
        assert rec["triton"] is False
        assert rec["sage_attention"] is False
        assert rec["warnings"]


class TestMemoria:
    def test_poca_vram_activa_lowvram(self):
        assert ph.build_recommendation(gpu(vram_gb=4.0))["lowvram"] is True

    def test_vram_suficiente_usa_modo_normal(self):
        assert ph.build_recommendation(gpu(vram_gb=12.0))["lowvram"] is False

    # WMI desborda AdapterRAM por encima de 4 GB, asi que la VRAM llega como
    # None: adivinar aqui fue lo que hacia la version anterior.
    def test_vram_desconocida_no_se_adivina(self):
        rec = ph.build_recommendation(gpu(vram_gb=None, source="wmi"))
        assert rec["vram_gb"] is None
        assert rec["lowvram"] is False
        assert any("VRAM" in w for w in rec["warnings"])


class TestNoNvidia:
    @pytest.mark.parametrize("vendor", ["AMD", "INTEL"])
    def test_no_se_declara_soportado(self, vendor):
        rec = ph.build_recommendation(gpu(vendor=vendor, compute=None))
        assert rec["supported"] is False
        assert rec["accelerator"] == "cpu"
        assert rec["triton"] is False
        assert rec["sage_attention"] is False

    def test_sin_gpu_cae_a_cpu(self):
        rec = ph.build_recommendation(gpu(vendor="NONE", model=None, vram_gb=None, compute=None))
        assert rec["supported"] is False
        assert rec["profile"] == "cpu-only"


class TestPerfil:
    def test_incluye_arquitectura_y_vram(self):
        assert ph.build_recommendation(gpu(compute="8.6", vram_gb=12.0))["profile"] == "nvidia-ampere-12gb"

    # Sin arquitectura conocida no debe salir 'nvidia-nvidia-...'.
    def test_sin_arquitectura_no_duplica_el_prefijo(self):
        perfil = ph.build_recommendation(gpu(compute=None, vram_gb=11.0))["profile"]
        assert perfil == "nvidia-11gb"


class TestContrato:
    def test_nunca_inventa_modelo_ni_fabricante(self):
        rec = ph.build_recommendation(gpu(vendor="NONE", model=None, vram_gb=None, compute=None))
        assert rec["model"] is None or rec["model"] == "Desconocido"
        assert rec["cuda_compute"] is None

    def test_la_fuente_de_deteccion_se_propaga(self):
        assert ph.build_recommendation(gpu(source="wmi"))["detection_source"] == "wmi"
