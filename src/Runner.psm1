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

    # ComfyUI 0.37+ arranca con el Manager apagado salvo que se pida: el
    # argumento paso de --disable-manager (opt-out) a --enable-manager.
    $useManager = $false
    if ($config.runtime.PSObject.Properties['enable_manager']) {
        $useManager = [bool]$config.runtime.enable_manager
    }

    # Los otros dos flags del grupo. ComfyUI los declara mutuamente
    # excluyentes, asi que si la configuracion trajera ambos activos se da
    # prioridad a la UI antigua y se avisa, en vez de dejar que argparse
    # aborte con un error que no explica de donde salio.
    $noManagerUi = $false
    $legacyUi    = $false
    if ($config.runtime.PSObject.Properties['disable_manager_ui']) {
        $noManagerUi = [bool]$config.runtime.disable_manager_ui
    }
    if ($config.runtime.PSObject.Properties['enable_manager_legacy_ui']) {
        $legacyUi = [bool]$config.runtime.enable_manager_legacy_ui
    }
    if ($noManagerUi -and $legacyUi) {
        Write-WarningMsg "disable_manager_ui y legacy_ui son excluyentes; se usa legacy_ui."
        $noManagerUi = $false
    }
    # --enable-manager-legacy-ui implica --enable-manager en ComfyUI.
    if ($legacyUi) { $useManager = $true }

    # --- Construir argumentos ------------------------------------------------
    $cmdArgs = @($mainPy)
    if ($useManager)  { $cmdArgs += "--enable-manager" }
    if ($noManagerUi) { $cmdArgs += "--disable-manager-ui" }
    if ($legacyUi)    { $cmdArgs += "--enable-manager-legacy-ui" }
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
    $managerEstado = if (-not $useManager) { "inactivo" }
                     elseif ($legacyUi)    { "activo, UI antigua" }
                     elseif ($noManagerUi) { "activo, sin UI" }
                     else                  { "activo" }
    Write-KeyVal "Manager"      $managerEstado
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
