# ==============================================================================
# Runner.psm1 - Lanzador de ComfyUI
# ==============================================================================

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Config.psm1") -DisableNameChecking

function Start-Comfy {
    [CmdletBinding()]
    param(
        [switch]$LowVRam,
        [switch]$HighVRam,
        [switch]$NoSage,
        [AllowNull()][string]$Listen = $null,
        [int]$Port = 0,
        [string[]]$ExtraArgs = @()
    )

    $rootDir = Get-ProjectRoot
    $config  = Get-ComfyConfig

    $comfyDir = Join-Path $rootDir $config.install.install_dir
    $mainPy   = Join-Path $comfyDir "main.py"
    $pyExe    = Join-Path $rootDir ".venv\Scripts\python.exe"

    if (-not (Test-Path -LiteralPath $mainPy)) {
        Write-ErrorMsg "No se encontro '$mainPy'. Ejecuta primero: .\comodo.ps1 setup"
        return $false
    }
    if (-not (Test-Path -LiteralPath $pyExe)) {
        Write-ErrorMsg "No se encontro el entorno virtual. Ejecuta primero: .\comodo.ps1 setup"
        return $false
    }

    # --- Resolver modo de memoria -------------------------------------------
    if ($LowVRam -and $HighVRam) {
        Write-ErrorMsg "--lowvram y --highvram son mutuamente excluyentes."
        return $false
    }

    if ($LowVRam)       { $useLow = $true;  $useHigh = $false }
    elseif ($HighVRam)  { $useLow = $false; $useHigh = $true }
    else {
        $useLow  = [bool]$config.runtime.lowvram
        $useHigh = [bool]$config.runtime.highvram
        if ($useLow -and $useHigh) {
            Write-WarningMsg "Config con lowvram y highvram activos a la vez; se usa lowvram."
            $useHigh = $false
        }
    }

    # SageAttention solo se pasa si ademas esta realmente instalado, segun lo
    # que registro el instalador. Pasar el flag sin la libreria aborta ComfyUI.
    $sageInstalled = [bool]$config.optimizations.sage_attention
    $useSage = (-not $NoSage) -and [bool]$config.runtime.sage_attention -and $sageInstalled
    if ((-not $NoSage) -and [bool]$config.runtime.sage_attention -and -not $sageInstalled) {
        Write-WarningMsg "sage_attention pedido pero no instalado; se inicia sin el."
    }

    $listenHost = if ($Listen) { $Listen } elseif ($config.runtime.listen) { $config.runtime.listen } else { "127.0.0.1" }
    $listenPort = if ($Port -gt 0) { $Port } elseif ($config.runtime.port) { [int]$config.runtime.port } else { 8188 }
    $preview    = if ($config.runtime.preview_method) { $config.runtime.preview_method } else { "auto" }

    # --- Construir argumentos ------------------------------------------------
    $cmdArgs = @($mainPy)
    if ($useLow)  { $cmdArgs += "--lowvram" }
    if ($useHigh) { $cmdArgs += "--highvram" }
    if ($useSage) { $cmdArgs += "--use-sage-attention" }
    $cmdArgs += @("--preview-method", $preview)
    $cmdArgs += @("--listen", $listenHost)
    $cmdArgs += @("--port", "$listenPort")

    if ($config.runtime.extra_args) { $cmdArgs += @($config.runtime.extra_args) }
    if ($ExtraArgs -and $ExtraArgs.Count -gt 0) { $cmdArgs += $ExtraArgs }

    # --- Reporte -------------------------------------------------------------
    $vramMode = if ($useLow) { "lowvram" } elseif ($useHigh) { "highvram" } else { "normal" }
    $gpuLabel = Format-ConfigValue $config.hardware.model "GPU no detectada"
    if ($config.hardware.vram_gb) { $gpuLabel += " ($($config.hardware.vram_gb) GB)" }

    Write-StepHeader "Iniciando ComfyUI"
    Write-KeyVal "GPU"           $gpuLabel
    Write-KeyVal "Modo VRAM"     $vramMode
    Write-KeyVal "SageAttention" $(if ($useSage) { "activo" } else { "inactivo" })
    Write-KeyVal "URL"           "http://${listenHost}:${listenPort}"

    if ($listenHost -eq "0.0.0.0") {
        Write-WarningMsg "Escuchando en 0.0.0.0: accesible desde toda la red local, sin autenticacion."
    }

    Write-Banner "==> ComfyUI en ejecucion. Ctrl+C para detener." -Level Success

    Push-Location $comfyDir
    try {
        & $pyExe $cmdArgs
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($code -ne 0) {
        Write-ErrorMsg "ComfyUI termino con codigo $code."
        return $false
    }
    return $true
}

Export-ModuleMember -Function 'Start-Comfy'
