# ==============================================================================
# Runner.psm1 - Lanzador de ComfyUI
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")
Import-Module (Join-Path $PSScriptRoot "Config.psm1")

function Start-Comfy {
    [CmdletBinding()]
    param(
        [switch]$LowVRam,
        [switch]$HighVRam,
        # Claves del registro que no deben pasar su flag en esta ejecucion.
        [string[]]$DisableAccelerators = @(),
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
        Write-ErrorMsg "No se encontro '$mainPy'. Ejecuta primero: .\comodo.ps1 provision apply"
        return $false
    }
    if (-not (Test-Path -LiteralPath $pyExe)) {
        Write-ErrorMsg "No se encontro el entorno virtual. Ejecuta primero: .\comodo.ps1 provision apply"
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

    # Flags de arranque de los aceleradores. Cada uno se pasa solo si el
    # perfil lo tiene habilitado (esta instalado) Y el interruptor de runtime
    # lo pide: pasar --use-sage-attention sin la libreria aborta ComfyUI.
    $accelFlags = @()
    $accelActivos = @()
    foreach ($a in @($config.accelerators)) {
        if (-not $a.runtime_flag) { continue }
        if ($DisableAccelerators -contains $a.key) { continue }
        $pedido = $true
        if ($config.runtime.PSObject.Properties[$a.key]) {
            $pedido = [bool]$config.runtime.($a.key)
        }
        if (-not $pedido) { continue }
        if (-not $a.enabled) {
            Write-WarningMsg "$($a.key) pedido pero no instalado; se inicia sin el."
            continue
        }
        $accelFlags += $a.runtime_flag
        $accelActivos += $a.key
    }

    $listenHost = if ($Listen) { $Listen } elseif ($config.runtime.listen) { $config.runtime.listen } else { "127.0.0.1" }
    $listenPort = if ($Port -gt 0) { $Port } elseif ($config.runtime.port) { [int]$config.runtime.port } else { 8188 }
    $preview    = if ($config.runtime.preview_method) { $config.runtime.preview_method } else { "auto" }

    # --- Construir argumentos ------------------------------------------------
    $cmdArgs = @($mainPy)
    if ($useLow)  { $cmdArgs += "--lowvram" }
    if ($useHigh) { $cmdArgs += "--highvram" }
    if ($accelFlags.Count -gt 0) { $cmdArgs += $accelFlags }
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
    Write-KeyVal "Aceleradores" $(if ($accelActivos.Count -gt 0) { $accelActivos -join ', ' } else { "ninguno" })
    Write-KeyVal "URL"           "http://${listenHost}:${listenPort}"

    if ($listenHost -eq "0.0.0.0") {
        Write-WarningMsg "Escuchando en 0.0.0.0: accesible desde toda la red local, sin autenticacion."
    }

    Write-Banner "==> ComfyUI en ejecucion. Ctrl+C para detener." -Level Success

    # Inicializado fuera del try: si la invocacion lanza, con Set-StrictMode
    # leer una variable sin asignar seria un error adicional que enmascararia
    # el fallo real.
    $code = 0
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
