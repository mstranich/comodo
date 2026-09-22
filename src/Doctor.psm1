# ==============================================================================
# Doctor.psm1 - Diagnostico del entorno
# ==============================================================================

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Config.psm1") -DisableNameChecking

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
    "triton": None, "triton_error": None,
    "sage_attention": None, "sage_error": None,
    "torch_error": None,
}

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

try:
    import triton
    status["triton"] = getattr(triton, "__version__", "instalado")
except Exception as exc:
    status["triton_error"] = str(exc)

try:
    import sageattention
    status["sage_attention"] = getattr(sageattention, "__version__", "instalado")
except Exception as exc:
    status["sage_error"] = str(exc)

print(json.dumps(status))
'@

    $diag = $null
    try {
        $raw = & $pyExe -c $doctorScript 2>&1
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
    $expectTriton = [bool]$config.optimizations.triton
    $expectSage   = [bool]$config.optimizations.sage_attention

    $tritonState = if ($diag.triton) { "OK (v$($diag.triton))" }
                   elseif ($expectTriton) { "FALTA (esperado por el perfil)" }
                   else { "no aplica a esta GPU" }
    $sageState   = if ($diag.sage_attention) { "OK (v$($diag.sage_attention))" }
                   elseif ($expectSage) { "FALTA (esperado por el perfil)" }
                   else { "no aplica a esta GPU" }

    Write-KeyVal "Triton"        $tritonState
    Write-KeyVal "SageAttention" $sageState

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
    if ($expectTriton -and -not $diag.triton) { $problems += "falta triton-windows" }
    if ($expectSage -and -not $diag.sage_attention) { $problems += "falta sageattention" }
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
