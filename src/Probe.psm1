# ==============================================================================
# Probe.psm1 - Deteccion de hardware y calibracion automatica del perfil
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")
Import-Module (Join-Path $PSScriptRoot "Config.psm1")

function Invoke-ProbeScript {
    <#
    .SYNOPSIS
        Ejecuta src/probe_hardware.py y devuelve su JSON ya deserializado.
    .DESCRIPTION
        Orden de preferencia del interprete: el venv del proyecto (si existe),
        luego 'uv run --no-project', luego el python del sistema. El script
        solo usa la libreria estandar, asi que cualquiera sirve.
        Devuelve $null si ninguno funciona.
    #>
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    $scriptPath = Join-Path $PSScriptRoot "probe_hardware.py"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-ErrorMsg "No se encontro el script de deteccion: $scriptPath"
        return $null
    }

    $interpreters = @()

    $pyVenv = Find-PythonInVenv
    if ($pyVenv) { $interpreters += ,@($pyVenv, (@($scriptPath) + $Arguments)) }

    $uvExe = Find-UvExecutable
    if ($uvExe) { $interpreters += ,@($uvExe, (@('run','--no-project','python',$scriptPath) + $Arguments)) }

    $pySystem = Get-Command "python" -ErrorAction SilentlyContinue
    if ($pySystem) { $interpreters += ,@($pySystem.Source, (@($scriptPath) + $Arguments)) }

    $lastError = $null

    foreach ($entry in $interpreters) {
        $exe = $entry[0]
        # No usar $args: es una variable automatica de PowerShell y asignarla
        # dentro de una funcion tiene efectos colaterales.
        $exeArgs = $entry[1]
        try {
            # stderr se conserva y se reporta si todo falla: silenciarlo era lo
            # que antes ocultaba la causa real de una deteccion fallida.
            $stdout = & $exe @exeArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                $lastError = ($stdout | Out-String).Trim()
                continue
            }
            $text = ($stdout | Out-String).Trim()
            if (-not $text) { continue }
            return ($text | ConvertFrom-Json)
        }
        catch {
            $lastError = "$_"
            continue
        }
    }

    if ($lastError) { Write-Info "Ultimo error del sondeo: $lastError" }
    return $null
}

function Sync-ComfyAcceleratorRegistry {
    <#
    .SYNOPSIS
        Pone al dia etc/config.json con la tabla ACCELERATORS del proyecto.
    .DESCRIPTION
        El registro vive en src/probe_hardware.py y se persiste en la
        configuracion, asi que una config escrita por una version anterior del
        gestor no conoce los aceleradores anadidos despues. Sin este refresco,
        'setup' los omitiria en silencio hasta que alguien volviera a ejecutar
        'probe' a mano.

        No vuelve a sondear el hardware: reevalua la tabla con el vendor y la
        capacidad de computo que ya estan guardados, de modo que es barato y no
        depende de que nvidia-smi responda.

        Fusiona en vez de sobrescribir: las claves que ya existian conservan su
        'enabled' (puede haberlo cambiado el usuario con 'set') y solo se
        refrescan sus metadatos; las claves nuevas entran con el valor que
        decide el hardware; las que ya no estan en la tabla se descartan.
    .OUTPUTS
        [bool] $true si la configuracion cambio.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][PSCustomObject]$Config)

    $vendor  = if ($Config.hardware.vendor) { $Config.hardware.vendor } else { "UNKNOWN" }
    $compute = if ($Config.hardware.cuda_compute) { "$($Config.hardware.cuda_compute)" } else { "" }

    $fresh = Invoke-ProbeScript -Arguments @('--accelerators', $vendor, $compute)
    if ($null -eq $fresh) {
        Write-WarningMsg "No se pudo releer el registro de aceleradores; se usa el guardado."
        return $false
    }

    $previous = @{}
    foreach ($a in @($Config.accelerators)) { $previous[$a.key] = $a }

    $merged  = @()
    $added   = @()
    $removed = @($previous.Keys | Where-Object { $_ -notin @($fresh | ForEach-Object { $_.key }) })

    foreach ($entry in @($fresh)) {
        if ($previous.ContainsKey($entry.key)) {
            # Respetar la eleccion previa del usuario para esta clave.
            $entry.enabled = [bool]$previous[$entry.key].enabled
        } else {
            $added += $entry.key
        }
        $merged += $entry
    }

    $changed = ($added.Count -gt 0) -or ($removed.Count -gt 0) -or
               (@($merged).Count -ne @($Config.accelerators).Count)

    $Config.accelerators = $merged

    if ($added.Count -gt 0) {
        Write-Info "Aceleradores nuevos en el registro: $($added -join ', ')"
    }
    if ($removed.Count -gt 0) {
        Write-Info "Aceleradores retirados del registro: $($removed -join ', ')"
    }

    return $changed
}

function Invoke-HardwareProbe {
    [CmdletBinding()]
    param([switch]$ShowOnly)

    Write-StepHeader "Deteccion de hardware (probe)"

    $scriptPath = Join-Path $PSScriptRoot "probe_hardware.py"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-ErrorMsg "No se encontro el script de deteccion: $scriptPath"
        return $null
    }

    $probeResult = Invoke-ProbeScript

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
    foreach ($a in @($probeResult.accelerators)) {
        $estado = if ($a.enabled) { "si" } else { "no" }
        Write-KeyVal $a.key "$estado ($($a.reason))"
    }
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

    # El registro completo (clave, extra, modulo, flag y motivo) se guarda tal
    # cual: es lo que consumen setup, upgrade, doctor y start, de modo que no
    # haya una segunda lista de aceleradores escrita en PowerShell.
    $cfg.accelerators = @($probeResult.accelerators)

    $cfg.runtime.lowvram        = [bool]$probeResult.lowvram
    $cfg.runtime.highvram       = [bool]$probeResult.highvram
    $cfg.runtime.preview_method = $probeResult.preview_method

    # Los aceleradores con flag de arranque llevan ademas un interruptor de
    # runtime, para poder desactivarlos sin desinstalarlos.
    foreach ($a in @($probeResult.accelerators)) {
        if ($a.runtime_flag) {
            Set-DefaultMember -Object $cfg.runtime -Name $a.key -Default $false
            $cfg.runtime.($a.key) = [bool]$a.enabled
        }
    }

    Save-ComfyConfig -Config $cfg
    Write-Success "Perfil guardado en etc/config.json."

    return $probeResult
}

Export-ModuleMember -Function @(
    'Invoke-HardwareProbe',
    'Invoke-ProbeScript',
    'Sync-ComfyAcceleratorRegistry'
)
