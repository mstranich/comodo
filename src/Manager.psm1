# ==============================================================================
# Manager.psm1 - Ajustes de ComfyUI-Manager (config.ini)
# ==============================================================================
#
# config.ini pertenece a ComfyUI-Manager, no al nucleo de ComfyUI, y vive
# dentro del directorio de instalacion, que 'reset' elimina entero. Por eso
# los valores que el usuario fija aqui se guardan ademas en etc/config.json
# (seccion 'manager') y se reaplican tras cada 'provision apply': sin eso, cada reset
# obligaria a repetirlos a mano.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")
Import-Module (Join-Path $PSScriptRoot "Config.psm1")

function Get-ManagerConfigPath {
    <#
    .SYNOPSIS
        Ruta de config.ini, o $null si ComfyUI-Manager no esta instalado.
    #>
    [CmdletBinding()]
    param()

    $config   = Get-ComfyConfig
    $comfyDir = Join-Path (Get-ProjectRoot) $config.install.install_dir
    $path     = Join-Path $comfyDir "user\__manager\config.ini"

    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Read-IniFile {
    <#
    .SYNOPSIS
        Lee un .ini plano en un diccionario ordenado.
    .DESCRIPTION
        Solo contempla la seccion [default], que es la unica que usa
        ComfyUI-Manager. Conserva el orden para poder reescribir el archivo
        sin reordenar lo que no tocamos.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    $result = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
        if ($trimmed.StartsWith('[')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        $result[$trimmed.Substring(0, $idx).Trim()] = $trimmed.Substring($idx + 1).Trim()
    }
    return $result
}

function Set-IniValue {
    <#
    .SYNOPSIS
        Cambia una clave de un .ini conservando el resto del archivo.
    .DESCRIPTION
        Se reescribe linea a linea en vez de regenerar el archivo: asi se
        preservan comentarios, orden y cualquier clave que ComfyUI-Manager
        anada en versiones futuras.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )

    $lines   = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $out     = @()
    $written = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $idx = $trimmed.IndexOf('=')
        if ($idx -gt 0 -and -not $trimmed.StartsWith('#') -and -not $trimmed.StartsWith(';') -and
            $trimmed.Substring(0, $idx).Trim() -eq $Key) {
            $out += "$Key = $Value"
            $written = $true
        } else {
            $out += $line
        }
    }

    if (-not $written) {
        # Clave nueva: va al final de [default].
        $out += "$Key = $Value"
    }

    Set-Content -LiteralPath $Path -Value $out -Encoding UTF8
}

function Get-ManagerOverrides {
    <#
    .SYNOPSIS
        Devuelve los valores que el usuario fijo, guardados en etc/config.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][PSCustomObject]$Config)

    Set-DefaultMember -Object $Config -Name 'manager' -Default ([PSCustomObject]@{})
    return $Config.manager
}

function Sync-ManagerConfig {
    <#
    .SYNOPSIS
        Reaplica sobre config.ini los valores guardados en etc/config.json.
    .DESCRIPTION
        La llama 'provision apply' despues de instalar los nodos, momento en que
        ComfyUI-Manager ya existe. Es lo que hace que los ajustes sobrevivan a
        un 'reset', que borra el directorio de instalacion completo.
    .OUTPUTS
        [bool] $true si se aplico algo.
    #>
    [CmdletBinding()]
    param()

    $config    = Get-ComfyConfig
    $overrides = Get-ManagerOverrides -Config $config
    $pending   = @($overrides.PSObject.Properties)

    if ($pending.Count -eq 0) { return $false }

    $iniPath = Get-ManagerConfigPath
    if (-not $iniPath) {
        Write-Info "ComfyUI-Manager no esta instalado; sus ajustes se aplicaran cuando lo este."
        return $false
    }

    $current = Read-IniFile -Path $iniPath
    $applied = @()

    foreach ($prop in $pending) {
        $existing = if ($current.Contains($prop.Name)) { $current[$prop.Name] } else { $null }
        if ("$existing" -ne "$($prop.Value)") {
            Set-IniValue -Path $iniPath -Key $prop.Name -Value "$($prop.Value)"
            $applied += $prop.Name
        }
    }

    if ($applied.Count -gt 0) {
        Write-Success "Ajustes de ComfyUI-Manager reaplicados: $($applied -join ', ')"
        Write-Info "Se leen al arrancar; reinicia ComfyUI para que surtan efecto."
        return $true
    }
    return $false
}

function Show-ManagerConfig {
    [CmdletBinding()]
    param()

    Write-StepHeader "Ajustes de ComfyUI-Manager (config.ini)"

    $config    = Get-ComfyConfig
    $overrides = Get-ManagerOverrides -Config $config
    $fixed     = @{}
    foreach ($p in $overrides.PSObject.Properties) { $fixed[$p.Name] = "$($p.Value)" }

    $iniPath = Get-ManagerConfigPath
    if (-not $iniPath) {
        Write-WarningMsg "ComfyUI-Manager no esta instalado; no hay config.ini."
        if ($fixed.Count -gt 0) {
            Write-Info "Valores guardados, pendientes de aplicar:"
            foreach ($k in $fixed.Keys) { Write-KeyVal $k $fixed[$k] }
        }
        return $true
    }

    Write-Info "Archivo: $iniPath"
    Write-Host ""

    foreach ($entry in (Read-IniFile -Path $iniPath).GetEnumerator()) {
        $valor = if ($entry.Value) { $entry.Value } else { "(vacio)" }
        # Marcar lo que fijo el usuario frente a lo que trae el Manager.
        if ($fixed.ContainsKey($entry.Key)) { $valor += "   $ColorGreen[fijado]$ColorReset" }
        Write-KeyVal $entry.Key $valor
    }

    Write-Host ""
    Write-Info "Cambiar: .\comodo.ps1 manager set <clave> <valor>"
    return $true
}

function Set-ManagerSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Key,
        [Parameter(Mandatory=$true, Position=1)][string]$Value
    )

    $config    = Get-ComfyConfig
    $overrides = Get-ManagerOverrides -Config $config
    $iniPath   = Get-ManagerConfigPath

    if ($iniPath) {
        $current = Read-IniFile -Path $iniPath
        if (-not $current.Contains($Key)) {
            Write-WarningMsg "'$Key' no existe hoy en config.ini; se anadira igualmente."
            Write-Info "Claves actuales: $((Read-IniFile -Path $iniPath).Keys -join ', ')"
        }
        Set-IniValue -Path $iniPath -Key $Key -Value $Value
        Write-Success "config.ini: $Key = $Value"
    } else {
        Write-WarningMsg "ComfyUI-Manager no esta instalado; se guarda para aplicarlo tras 'provision apply'."
    }

    # Persistir para sobrevivir a un reset.
    Set-DefaultMember -Object $overrides -Name $Key -Default $Value
    $overrides.$Key = $Value
    Save-ComfyConfig -Config $config

    Write-Info "Guardado en etc/config.json; se reaplica tras cada 'provision apply'."
    Write-Info "ComfyUI lee config.ini al arrancar: reinicialo con el servidor detenido."
    return $true
}

function Reset-ManagerSetting {
    <#
    .SYNOPSIS
        Deja de fijar una clave; config.ini conserva su valor actual.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true, Position=0)][string]$Key)

    $config    = Get-ComfyConfig
    $overrides = Get-ManagerOverrides -Config $config

    if ($null -eq $overrides.PSObject.Properties[$Key]) {
        Write-WarningMsg "'$Key' no estaba fijado por el gestor."
        return $false
    }

    $overrides.PSObject.Properties.Remove($Key)
    Save-ComfyConfig -Config $config

    Write-Success "'$Key' ya no lo fija el gestor."
    # No se toca config.ini: quitar el override no implica revertir el valor,
    # que puede ser el que el usuario quiere. Se dice explicitamente.
    Write-Info "config.ini conserva su valor actual; cambialo con 'manager set' si hace falta."
    return $true
}

Export-ModuleMember -Function @(
    'Show-ManagerConfig',
    'Set-ManagerSetting',
    'Reset-ManagerSetting',
    'Sync-ManagerConfig',
    'Get-ManagerConfigPath',
    'Read-IniFile',
    'Set-IniValue'
)
