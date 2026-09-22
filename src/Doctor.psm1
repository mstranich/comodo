# ==============================================================================
# Doctor.psm1 - Diagnostico del entorno
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")
Import-Module (Join-Path $PSScriptRoot "Config.psm1")

function Invoke-ComfyDoctor {
    [CmdletBinding()]
    param()

    Write-StepHeader "Diagnostico del entorno (doctor)"

    $rootDir  = Get-ProjectRoot
    $config   = Get-ComfyConfig
    $pyExe    = Join-Path $rootDir ".venv\Scripts\python.exe"
    $comfyDir = Join-Path $rootDir $config.install.install_dir

    if (-not (Test-Path -LiteralPath $pyExe)) {
        Write-ErrorMsg "No existe el entorno virtual. Ejecuta primero: .\comodo.ps1 setup"
        return $false
    }
    Write-Success "Entorno virtual: $pyExe"

    $doctorScript = @'
import json, sys

status = {
    "python_version": sys.version.split()[0],
    "torch": None, "cuda_available": False, "cuda_version": None,
    "device_name": None, "vram_gb": None,
    "aimdo": None, "kitchen": None,
    "torch_error": None,
    "accelerators": {},
}

# Los modulos a comprobar llegan como argumento: el registro de aceleradores
# vive en src/probe_hardware.py y se propaga por etc/config.json, de modo que
# este script no repite ninguna lista.
_modules = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

# comfy-aimdo (DynamicVRAM) y comfy-kitchen llegan como dependencias pineadas
# en el requirements.txt de ComfyUI, no se instalan por separado.
import importlib.metadata as _md
for _key, _dist in (("aimdo", "comfy-aimdo"), ("kitchen", "comfy-kitchen")):
    try:
        status[_key] = _md.version(_dist)
    except Exception:
        pass

try:
    import torch
    status["torch"] = torch.__version__
    status["cuda_version"] = torch.version.cuda
    status["cuda_available"] = torch.cuda.is_available()
    if status["cuda_available"]:
        status["device_name"] = torch.cuda.get_device_name(0)
        props = torch.cuda.get_device_properties(0)
        status["vram_gb"] = round(props.total_memory / (1024 ** 3), 2)
except Exception as exc:
    status["torch_error"] = str(exc)

for _key, _mod in _modules.items():
    try:
        _m = __import__(_mod)
        status["accelerators"][_key] = {
            "version": getattr(_m, "__version__", "instalado"), "error": None
        }
    except Exception as exc:
        status["accelerators"][_key] = {"version": None, "error": str(exc)}

print(json.dumps(status))
'@

    # Mapa clave -> modulo, tomado del registro guardado por 'probe'.
    $moduleMap = @{}
    foreach ($a in @($config.accelerators)) {
        if ($a.PSObject.Properties['module'] -and $a.module) { $moduleMap[$a.key] = $a.module }
    }
    $moduleJson = ($moduleMap | ConvertTo-Json -Compress)
    if (-not $moduleJson) { $moduleJson = '{}' }

    $diag = $null
    try {
        $raw = & $pyExe -c $doctorScript $moduleJson 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($raw | Out-String).Trim() }
        $diag = ($raw | Out-String).Trim() | ConvertFrom-Json
    }
    catch {
        Write-ErrorMsg "Fallo el diagnostico en Python: $_"
        return $false
    }

    Write-Host "`n  [Python & PyTorch]" -ForegroundColor DarkCyan
    Write-KeyVal "Python"  (Format-ConfigValue $diag.python_version)
    Write-KeyVal "PyTorch" (Format-ConfigValue $diag.torch "no instalado")
    if ($diag.torch_error) { Write-WarningMsg "torch: $($diag.torch_error)" }

    Write-KeyVal "CUDA" $(if ($diag.cuda_available) { "disponible (build CUDA $($diag.cuda_version))" } else { "no disponible" })
    if ($diag.cuda_available) {
        Write-KeyVal "GPU"  (Format-ConfigValue $diag.device_name)
        Write-KeyVal "VRAM" "$($diag.vram_gb) GB"
    }

    # --- Aceleradores: se comparan contra lo que el perfil esperaba ----------
    Write-Host "`n  [Aceleradores]" -ForegroundColor DarkCyan
    $accelFaltantes = @()

    if (@($config.accelerators).Count -eq 0) {
        Write-Host "    (sin registro: ejecuta probe)" -ForegroundColor DarkGray
    }
    foreach ($a in @($config.accelerators)) {
        $found = $null
        if ($diag.accelerators.PSObject.Properties[$a.key]) {
            $found = $diag.accelerators.($a.key)
        }
        $estado = if ($found -and $found.version) { "OK (v$($found.version))" }
                  elseif ($a.enabled)             { "FALTA (esperado por el perfil)" }
                  else                            { "no aplica ($($a.reason))" }
        Write-KeyVal $a.key $estado
        if ($a.enabled -and -not ($found -and $found.version)) {
            $accelFaltantes += $a.key
        }
    }
    Write-KeyVal "DynamicVRAM"   $(if ($diag.aimdo) { "OK (comfy-aimdo v$($diag.aimdo))" } else { "no disponible" })
    Write-KeyVal "comfy-kitchen" $(if ($diag.kitchen) { "OK (v$($diag.kitchen))" } else { "no disponible" })

    # comfy-kitchen deshabilita sus backends optimizados si el build de CUDA de
    # PyTorch es anterior al objetivo del perfil. Es un fallo silencioso: todo
    # arranca bien y solo se pierde rendimiento, asi que se comprueba aqui.
    $targetCuda    = $config.install.cuda_version
    $installedCuda = $diag.cuda_version
    $cudaOutdated  = $false
    if ($targetCuda -and $installedCuda) {
        try {
            $cudaOutdated = ([version]$installedCuda -lt [version]$targetCuda)
        } catch { $cudaOutdated = $false }
    }
    Write-KeyVal "Build CUDA" $(
        if (-not $installedCuda) { "desconocido" }
        elseif ($cudaOutdated)   { "$installedCuda (el perfil pide $targetCuda)" }
        else                     { "$installedCuda" }
    )

    Write-Host "`n  [ComfyUI]" -ForegroundColor DarkCyan
    $mainPy = Join-Path $comfyDir "main.py"
    Write-KeyVal "Codigo" $(if (Test-Path -LiteralPath $mainPy) { "instalado" } else { "falta (ejecuta setup)" })

    $customNodesDir = Join-Path $comfyDir "custom_nodes"
    if (Test-Path -LiteralPath $customNodesDir) {
        $nodes = @(Get-ChildItem -Path $customNodesDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(__pycache__|\.)' })
        Write-KeyVal "Nodos instalados" "$($nodes.Count)"
    }

    # --- Veredicto ------------------------------------------------------------
    # El veredicto compara el estado real contra lo que el perfil detectado
    # esperaba, en vez de exigir una configuracion fija para todos.
    $problems = @()
    if (-not $diag.torch)        { $problems += "PyTorch no esta instalado" }
    if ($config.hardware.accelerator -eq 'cuda' -and -not $diag.cuda_available) {
        $problems += "se detecto una GPU NVIDIA pero PyTorch no ve CUDA"
    }
    foreach ($k in $accelFaltantes) { $problems += "falta el acelerador '$k'" }
    if ($cudaOutdated) {
        $problems += "PyTorch esta compilado contra CUDA $installedCuda pero el perfil pide $targetCuda; comfy-kitchen deshabilitara sus backends optimizados (reinstala con: setup --force)"
    }
    if (-not (Test-Path -LiteralPath $mainPy)) { $problems += "falta el codigo de ComfyUI" }

    Write-Host ""
    if ($problems.Count -eq 0) {
        $perfil = Format-ConfigValue $config.hardware.profile "sin perfil"
        Write-Banner "Entorno coherente con el perfil detectado ($perfil)." -Level Success
        return $true
    }

    Write-Banner "Se encontraron $($problems.Count) problema(s):" -Level Warning
    foreach ($p in $problems) { Write-WarningMsg $p }
    Write-Info "Reejecuta '.\comodo.ps1 setup' para repararlos."
    return $false
}

Export-ModuleMember -Function 'Invoke-ComfyDoctor'
