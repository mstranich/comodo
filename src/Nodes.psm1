# ==============================================================================
# Nodes.psm1 - Gestion de nodos personalizados (custom_nodes)
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")
Import-Module (Join-Path $PSScriptRoot "Config.psm1")

function Get-CustomNodesDirectory {
    $config   = Get-ComfyConfig
    $comfyDir = Join-Path (Get-ProjectRoot) $config.install.install_dir
    $nodesDir = Join-Path $comfyDir "custom_nodes"
    if (-not (Test-Path -LiteralPath $nodesDir)) {
        New-Item -ItemType Directory -Path $nodesDir -Force | Out-Null
    }
    return $nodesDir
}

function Test-GitUrl {
    <#
    .SYNOPSIS
        Acepta solo URLs de repositorio plausibles (https o ssh).
    #>
    param([Parameter(Mandatory=$true)][string]$Url)
    return ($Url -match '^(https://|git@|ssh://)')
}

function Show-CustomNodesList {
    [CmdletBinding()]
    param()

    Write-StepHeader "Nodos personalizados instalados"

    $nodesDir = Get-CustomNodesDirectory
    $gitExe   = Find-GitExecutable
    $config   = Get-ComfyConfig

    $items = @(Get-ChildItem -Path $nodesDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(__pycache__|\.)' })

    if ($items.Count -eq 0) {
        Write-Info "No hay nodos instalados en $nodesDir"
        Write-Info "Anade uno con: .\comodo.ps1 custom-nodes add <url_git>"
        return $true
    }

    foreach ($item in $items) {
        $isGit     = Test-Path -LiteralPath (Join-Path $item.FullName ".git")
        $remoteUrl = "sin repositorio Git"
        $branch    = $null
        $commit    = $null

        if ($isGit -and $gitExe) {
            $remoteUrl = (& $gitExe -C $item.FullName config --get remote.origin.url 2>$null)
            if (-not $remoteUrl) { $remoteUrl = "local (sin remoto)" }
            $branch = (& $gitExe -C $item.FullName rev-parse --abbrev-ref HEAD 2>$null)
            $commit = (& $gitExe -C $item.FullName rev-parse --short HEAD 2>$null)
        }

        $tracked = @($config.custom_nodes | Where-Object { $_.name -eq $item.Name }).Count -gt 0
        $badge = if ($tracked) { "$ColorGreen[registrado]$ColorReset" } else { "$ColorYellow[no registrado]$ColorReset" }

        Write-Host "`n  $ColorBold$ColorYellow* $($item.Name)$ColorReset $badge"
        Write-Host "    $ColorGray- repo:$ColorReset $remoteUrl"
        if ($isGit -and $branch) {
            Write-Host "    $ColorGray- rama:$ColorReset $branch ($commit)"
        }
    }
    Write-Host ""
    return $true
}

function Add-CustomNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Url,
        [Parameter(Position=1)][AllowNull()][string]$Name = $null
    )

    $gitExe = Find-GitExecutable
    $uvExe  = Find-UvExecutable
    $pyExe  = Find-PythonInVenv

    if (-not $gitExe) {
        Write-ErrorMsg "Git no esta disponible."
        return $false
    }
    if (-not (Test-GitUrl -Url $Url)) {
        Write-ErrorMsg "URL no valida: '$Url'. Debe empezar por https://, git@ o ssh://"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $clean = $Url.TrimEnd('/')
        if ($clean.EndsWith('.git')) { $clean = $clean.Substring(0, $clean.Length - 4) }
        $Name = $clean.Split('/')[-1]
    }

    $nodesDir = Get-CustomNodesDirectory

    # Validar antes de tocar el disco: el nombre se usa para construir una ruta.
    if (-not (Test-SafeChildPath -ParentDir $nodesDir -Name $Name)) {
        Write-ErrorMsg "Nombre de nodo no valido: '$Name'."
        Write-Info "Debe ser un nombre de carpeta simple, sin separadores de ruta."
        return $false
    }

    $targetDir = Join-Path $nodesDir $Name
    Write-StepHeader "Anadiendo nodo: $Name"

    if (Test-Path -LiteralPath $targetDir) {
        Write-WarningMsg "Ya existe: $targetDir"
        $confirm = Read-Host "Actualizarlo con git pull? (s/N)"
        if ($confirm -notmatch '^(s|si|y|yes)$') {
            Write-Info "Operacion cancelada."
            return $false
        }
        & $gitExe -C $targetDir pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            Write-WarningMsg "No se pudo actualizar (cambios locales o divergencia)."
        }
    }
    else {
        Write-Info "Clonando $Url..."
        & $gitExe clone --depth 1 $Url $targetDir
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "Fallo al clonar desde $Url"
            return $false
        }
        Write-Success "Repositorio clonado."
    }

    $reqFile = Join-Path $targetDir "requirements.txt"
    if (Test-Path -LiteralPath $reqFile) {
        if (-not $uvExe -or -not $pyExe) {
            Write-WarningMsg "El nodo tiene requirements.txt pero falta uv o el venv; instalalo con 'setup'."
        }
        else {
            Write-Info "Instalando dependencias del nodo..."
            if (Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments @('install','-r',$reqFile)) {
                Write-Success "Dependencias instaladas."
            } else {
                Write-WarningMsg "Fallaron las dependencias; el nodo puede no cargar."
            }
        }
    }

    # Registrar para que 'setup' lo reconstruya en una instalacion limpia.
    $config   = Get-ComfyConfig
    $existing = @($config.custom_nodes | Where-Object { $_.name -eq $Name })
    if ($existing.Count -eq 0) {
        $config.custom_nodes = @($config.custom_nodes) + [PSCustomObject]@{
            name = $Name; url = $Url; enabled = $true
        }
        Save-ComfyConfig -Config $config
        Write-Success "'$Name' registrado en etc/config.json."
    } else {
        Write-Info "'$Name' ya estaba registrado."
    }

    Write-Banner "[OK] Nodo '$Name' instalado." -Level Success
    return $true
}

function Remove-CustomNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Name,
        [switch]$Force
    )

    $nodesDir = Get-CustomNodesDirectory

    if (-not (Test-SafeChildPath -ParentDir $nodesDir -Name $Name)) {
        Write-ErrorMsg "Nombre de nodo no valido: '$Name'."
        Write-Info "Solo se permiten nombres de carpeta simples dentro de custom_nodes."
        return $false
    }

    $targetDir = Join-Path $nodesDir $Name
    Write-StepHeader "Eliminando nodo: $Name"

    if (-not (Test-Path -LiteralPath $targetDir)) {
        Write-WarningMsg "No existe la carpeta: $targetDir"
    }
    else {
        if (-not $Force) {
            Write-WarningMsg "Se eliminara permanentemente: $targetDir"
            # Default seguro: solo una respuesta afirmativa explicita borra.
            $confirm = Read-Host "Confirmas la eliminacion? (s/N)"
            if ($confirm -notmatch '^(s|si|y|yes)$') {
                Write-Info "Eliminacion cancelada."
                return $false
            }
        }
        Remove-Item -LiteralPath $targetDir -Recurse -Force
        Write-Success "Carpeta eliminada."
    }

    $config = Get-ComfyConfig
    $before = @($config.custom_nodes).Count
    $config.custom_nodes = @($config.custom_nodes | Where-Object { $_.name -ne $Name })
    if (@($config.custom_nodes).Count -lt $before) {
        Save-ComfyConfig -Config $config
        Write-Success "'$Name' eliminado de etc/config.json."
    }

    Write-Banner "[OK] Nodo '$Name' eliminado." -Level Success
    return $true
}

Export-ModuleMember -Function @(
    'Show-CustomNodesList',
    'Add-CustomNode',
    'Remove-CustomNode'
)
