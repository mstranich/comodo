# ==============================================================================
# Accelerators.psm1 - Gestion de aceleradores (list, enable, disable)
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")
Import-Module (Join-Path $PSScriptRoot "Config.psm1")
Import-Module (Join-Path $PSScriptRoot "Probe.psm1")

function Show-AcceleratorList {
    [CmdletBinding()]
    param()

    Write-StepHeader "Aceleradores"

    $config = Get-ComfyConfig
    # Igual que setup y doctor: poner al dia el registro contra la tabla del
    # proyecto antes de mostrarlo.
    if (Sync-ComfyAcceleratorRegistry -Config $config) {
        Save-ComfyConfig -Config $config
    }

    $all = @($config.accelerators)
    if ($all.Count -eq 0) {
        Write-Info "Sin registro todavia. Ejecuta: .\comodo.ps1 probe"
        return $true
    }

    foreach ($a in $all) {
        $estado = if ($a.enabled) { "$ColorGreen[activo]$ColorReset" } else { "$ColorYellow[inactivo]$ColorReset" }
        Write-Host "`n  $ColorBold$ColorYellow* $($a.key)$ColorReset $estado"
        Write-Host "    $ColorGray- paquete:$ColorReset $($a.package)  (extra: $($a.extra))"
        Write-Host ("    $ColorGray- minimo:$ColorReset  sm_{0:N1}" -f [double]$a.min_compute)
        if ($a.runtime_flag) {
            Write-Host "    $ColorGray- flag:$ColorReset    $($a.runtime_flag)"
        }
        if ($a.PSObject.Properties['reason'] -and $a.reason) {
            Write-Host "    $ColorGray- motivo:$ColorReset  $($a.reason)"
        }
    }
    Write-Host ""
    Write-Info "Activar/desactivar: .\comodo.ps1 accel <enable|disable> <clave>"
    return $true
}

function Set-AcceleratorEnabled {
    <#
    .SYNOPSIS
        Activa o desactiva un acelerador del registro.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Name,
        [Parameter(Mandatory=$true)][bool]$Enabled
    )

    $config = Get-ComfyConfig
    if (Sync-ComfyAcceleratorRegistry -Config $config) {
        Save-ComfyConfig -Config $config
    }

    $key = Resolve-ComfyAcceleratorKey -Config $config -Name $Name
    if (-not $key) {
        Write-ErrorMsg "Acelerador no reconocido: '$Name'."
        $claves = @($config.accelerators | ForEach-Object { $_.key })
        if ($claves.Count -gt 0) {
            Write-Info "Disponibles: $($claves -join ', ')"
        } else {
            Write-Info "El registro esta vacio. Ejecuta: .\comodo.ps1 probe"
        }
        return $false
    }

    $accel = Get-ComfyAccelerator -Config $config -Key $key

    # Avisar si se fuerza uno que el hardware no soporta: se permite (puede
    # haber motivos para probarlo) pero no debe pasar inadvertido.
    if ($Enabled) {
        $vendor  = if ($config.hardware.vendor) { $config.hardware.vendor } else { "UNKNOWN" }
        $compute = if ($config.hardware.cuda_compute) { "$($config.hardware.cuda_compute)" } else { "" }
        $fresh = Invoke-ProbeScript -Arguments @('--accelerators', $vendor, $compute)
        if ($fresh) {
            $verdict = @($fresh | Where-Object { $_.key -eq $key }) | Select-Object -First 1
            if ($verdict -and -not $verdict.enabled) {
                Write-WarningMsg "El hardware detectado no lo soporta: $($verdict.reason)."
                Write-WarningMsg "Se activa igualmente; puede fallar al instalar o al arrancar."
            }
        }
    }

    $accel.enabled = $Enabled

    # Los que tienen flag de arranque llevan ademas interruptor de runtime.
    if ($accel.runtime_flag) {
        Set-DefaultMember -Object $config.runtime -Name $key -Default $false
        $config.runtime.$key = $Enabled
    }

    Save-ComfyConfig -Config $config

    $verbo = if ($Enabled) { "activado" } else { "desactivado" }
    Write-Success "Acelerador '$key' $verbo."
    Write-Info "Aplica los cambios con: .\comodo.ps1 setup"
    return $true
}

Export-ModuleMember -Function @(
    'Show-AcceleratorList',
    'Set-AcceleratorEnabled'
)
