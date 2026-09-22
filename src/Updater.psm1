# ==============================================================================
# Updater.psm1 - Actualizacion de ComfyUI, nodos y aceleradores
# ==============================================================================

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Config.psm1") -DisableNameChecking

function Update-GitRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$GitExe,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label
    )

    & $GitExe -C $Path pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        # --ff-only evita crear commits de merge en el repo del usuario: si hay
        # cambios locales es mejor avisar que fusionar a ciegas.
        Write-WarningMsg "$Label no se pudo actualizar (cambios locales o divergencia)."
        return $false
    }
    Write-Success "$Label actualizado."
    return $true
}

function Invoke-ComfyUpgrade {
    [CmdletBinding()]
    param(
        [switch]$CoreOnly,
        [switch]$NodesOnly
    )

    $rootDir = Get-ProjectRoot
    $config  = Get-ComfyConfig

    $gitExe = Find-GitExecutable
    $uvExe  = Find-UvExecutable
    $pyExe  = Find-PythonInVenv

    if (-not $gitExe) {
        Write-ErrorMsg "No se encontro Git."
        return $false
    }
    if (-not $pyExe) {
        Write-ErrorMsg "No existe el entorno virtual. Ejecuta primero: .\comodo.ps1 setup"
        return $false
    }

    $comfyDir = Join-Path $rootDir $config.install.install_dir
    $failures = 0

    # --- 1. Nucleo -----------------------------------------------------------
    if (-not $NodesOnly) {
        if (Test-Path -LiteralPath (Join-Path $comfyDir ".git")) {
            Write-StepHeader "Actualizando ComfyUI"
            if (-not (Update-GitRepo -GitExe $gitExe -Path $comfyDir -Label "ComfyUI")) { $failures++ }

            $reqFile = Join-Path $comfyDir "requirements.txt"
            if ($uvExe -and (Test-Path -LiteralPath $reqFile)) {
                Write-Info "Sincronizando dependencias del nucleo..."
                if (-not (Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments @('install','-r',$reqFile))) {
                    Write-WarningMsg "Fallaron dependencias del nucleo."
                    $failures++
                }
            }
        } else {
            Write-WarningMsg "ComfyUI no es un repositorio Git; se omite su actualizacion."
        }
    }

    # --- 2. Nodos ------------------------------------------------------------
    if (-not $CoreOnly) {
        Write-StepHeader "Actualizando nodos personalizados"
        $customNodesDir = Join-Path $comfyDir "custom_nodes"

        if (-not (Test-Path -LiteralPath $customNodesDir)) {
            Write-Info "No hay directorio custom_nodes."
        } else {
            $nodeDirs = @(Get-ChildItem -Path $customNodesDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ".git") })

            if ($nodeDirs.Count -eq 0) {
                Write-Info "No hay nodos con repositorio Git."
            }
            foreach ($node in $nodeDirs) {
                if (-not (Update-GitRepo -GitExe $gitExe -Path $node.FullName -Label $node.Name)) {
                    $failures++
                    continue
                }
                $nodeReq = Join-Path $node.FullName "requirements.txt"
                if ($uvExe -and (Test-Path -LiteralPath $nodeReq)) {
                    if (-not (Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments @('install','-r',$nodeReq))) {
                        Write-WarningMsg "Fallaron dependencias de $($node.Name)."
                        $failures++
                    }
                }
            }
        }
    }

    # --- 3. Aceleradores -----------------------------------------------------
    # Solo se actualiza lo que el perfil de hardware habilito. Antes se
    # actualizaba siempre, reinstalando paquetes en maquinas que no los usan.
    if ($uvExe -and -not $NodesOnly) {
        $packages = @()
        if ($config.optimizations.triton)         { $packages += 'triton-windows' }
        if ($config.optimizations.sage_attention) { $packages += 'sageattention' }

        if ($packages.Count -gt 0) {
            Write-StepHeader "Actualizando aceleradores"
            Write-Info "Paquetes: $($packages -join ', ')"
            if (-not (Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments (@('install','--upgrade') + $packages))) {
                Write-WarningMsg "Fallo la actualizacion de aceleradores."
                $failures++
            } else {
                Write-Success "Aceleradores al dia."
            }
        }
    }

    Write-Host ""
    if ($failures -eq 0) {
        Write-Banner "[OK] Actualizacion completada." -Level Success
        return $true
    }
    Write-Banner "Actualizacion terminada con $failures incidencia(s). Revisa los avisos." -Level Warning
    return $false
}

Export-ModuleMember -Function 'Invoke-ComfyUpgrade'
