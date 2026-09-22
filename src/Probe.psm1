# ==============================================================================
# Probe.psm1 - Deteccion de hardware y calibracion automatica del perfil
# ==============================================================================

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Config.psm1") -DisableNameChecking

function Invoke-HardwareProbe {
    [CmdletBinding()]
    param([switch]$ShowOnly)

    Write-StepHeader "Deteccion de hardware (probe)"

    $scriptPath = Join-Path $PSScriptRoot "probe_hardware.py"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-ErrorMsg "No se encontro el script de deteccion: $scriptPath"
        return $null
    }

    # Orden de preferencia para el interprete: el venv del proyecto (si ya
    # existe), luego 'uv run', luego el python del sistema. El script solo usa
    # la libreria estandar, asi que cualquiera sirve.
    $interpreters = @()

    $pyVenv = Find-PythonInVenv
    if ($pyVenv) { $interpreters += ,@($pyVenv, @($scriptPath)) }

    $uvExe = Find-UvExecutable
    if ($uvExe) { $interpreters += ,@($uvExe, @('run','--no-project','python',$scriptPath)) }

    $pySystem = Get-Command "python" -ErrorAction SilentlyContinue
    if ($pySystem) { $interpreters += ,@($pySystem.Source, @($scriptPath)) }

    $probeResult = $null
    $lastError = $null

    foreach ($entry in $interpreters) {
        $exe  = $entry[0]
        $args = $entry[1]
        try {
            # stderr se conserva y se reporta si todo falla: silenciarlo era lo
            # que antes ocultaba la causa real de una deteccion fallida.
            $stdout = & $exe @args 2>&1
            if ($LASTEXITCODE -ne 0) {
                $lastError = ($stdout | Out-String).Trim()
                continue
            }
            $text = ($stdout | Out-String).Trim()
            if (-not $text) { continue }
            $probeResult = $text | ConvertFrom-Json
            break
        }
        catch {
            $lastError = "$_"
            continue
        }
    }

    if ($null -eq $probeResult) {
        # Antes habia aqui un fallback que inventaba una GPU concreta. Escribir
        # datos falsos en config.json es peor que fallar: el resto del gestor
        # tomaria decisiones de instalacion sobre hardware inexistente.
        Write-ErrorMsg "No se pudo detectar el hardware."
        if ($lastError) { Write-Info "Ultimo error: $lastError" }
        Write-Info "Comprueba que 'uv' o 'python' esten disponibles y reintenta."
        return $null
    }

    # --- Reporte -------------------------------------------------------------
    Write-Host "`n  [Hardware detectado]" -ForegroundColor DarkCyan
    Write-KeyVal "Fabricante"   (Format-ConfigValue $probeResult.vendor)
    Write-KeyVal "Modelo"       (Format-ConfigValue $probeResult.model)
    Write-KeyVal "VRAM"         $(if ($probeResult.vram_gb) { "$($probeResult.vram_gb) GB" } else { "no determinada" })
    Write-KeyVal "Arquitectura" (Format-ConfigValue $probeResult.arch)
    Write-KeyVal "Compute"      $(if ($probeResult.cuda_compute) { "sm_$($probeResult.cuda_compute)" } else { "no determinado" })
    Write-KeyVal "Driver"       (Format-ConfigValue $probeResult.driver)
    Write-KeyVal "Fuente"       (Format-ConfigValue $probeResult.detection_source)

    Write-Host "`n  [Configuracion recomendada]" -ForegroundColor DarkCyan
    Write-KeyVal "Acelerador"   (Format-ConfigValue $probeResult.accelerator)
    Write-KeyVal "CUDA"         (Format-ConfigValue $probeResult.cuda_version "no aplica")
    Write-KeyVal "Indice PyTorch" (Format-ConfigValue $probeResult.torch_index_url)
    Write-KeyVal "Triton"       $(if ($probeResult.triton) { "si" } else { "no" })
    Write-KeyVal "SageAttention" $(if ($probeResult.sage_attention) { "si" } else { "no" })
    Write-KeyVal "Modo VRAM"    $(if ($probeResult.lowvram) { "lowvram" } else { "normal" })
    Write-KeyVal "Perfil"       (Format-ConfigValue $probeResult.profile)

    if ($probeResult.warnings -and @($probeResult.warnings).Count -gt 0) {
        Write-Host ""
        foreach ($w in @($probeResult.warnings)) { Write-WarningMsg $w }
    }

    $level = if ($probeResult.supported) { 'Success' } else { 'Warning' }
    Write-Banner $probeResult.summary -Level $level

    if ($ShowOnly) {
        Write-Info "--show: no se modifico etc/config.json."
        return $probeResult
    }

    # --- Persistir -----------------------------------------------------------
    $cfg = Get-ComfyConfig

    $cfg.hardware.vendor           = $probeResult.vendor
    $cfg.hardware.model            = $probeResult.model
    $cfg.hardware.vram_gb          = $probeResult.vram_gb
    $cfg.hardware.cuda_compute     = $probeResult.cuda_compute
    $cfg.hardware.arch             = $probeResult.arch
    $cfg.hardware.profile          = $probeResult.profile
    $cfg.hardware.accelerator      = $probeResult.accelerator
    $cfg.hardware.detection_source = $probeResult.detection_source

    $cfg.install.cuda_version    = $probeResult.cuda_version
    $cfg.install.torch_index_url = $probeResult.torch_index_url

    $cfg.optimizations.triton         = [bool]$probeResult.triton
    $cfg.optimizations.sage_attention = [bool]$probeResult.sage_attention

    $cfg.runtime.lowvram        = [bool]$probeResult.lowvram
    $cfg.runtime.highvram       = [bool]$probeResult.highvram
    $cfg.runtime.sage_attention = [bool]$probeResult.sage_attention
    $cfg.runtime.preview_method = $probeResult.preview_method

    Save-ComfyConfig -Config $cfg
    Write-Success "Perfil guardado en etc/config.json."

    return $probeResult
}

Export-ModuleMember -Function 'Invoke-HardwareProbe'
