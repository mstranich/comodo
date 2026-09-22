# ==============================================================================
# Checker.psm1 - Verificacion y Resolucion de Dependencias del Sistema
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")

function Update-SessionPath {
    <#
    .SYNOPSIS
        Incorpora al PATH de la sesion las rutas nuevas de Machine y User.
    .DESCRIPTION
        Se anaden unicamente las entradas que falten, en lugar de reemplazar
        $env:PATH por Machine+User: esa sustitucion descartaba todo lo que la
        sesion hubiera anadido al PATH de proceso (venvs activados, etc).
    #>
    $existing = @($env:PATH -split ';' | Where-Object { $_ })
    $fromReg  = @(
        [System.Environment]::GetEnvironmentVariable("Path", "Machine"),
        [System.Environment]::GetEnvironmentVariable("Path", "User")
    ) -join ';' -split ';' | Where-Object { $_ }

    $missing = @($fromReg | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -gt 0) {
        $env:PATH = ($existing + $missing) -join ';'
    }
}

function Invoke-PreRequisites {
    [CmdletBinding()]
    param(
        [switch]$DryRun = $false
    )

    Write-StepHeader "Comprobacion de Dependencias Previas (pre-requisites)"
    if ($DryRun) {
        Write-Info "Modo DRY-RUN activo: Solo se inspeccionara el sistema, sin realizar cambios."
    }

    $allOk = $true

    # 1. PowerShell Core (pwsh)
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -ge 7) {
        Write-Success "PowerShell Core: v$($psVer.ToString())"
    } else {
        Write-WarningMsg "Estas ejecutando Windows PowerShell $($psVer.Major). Se recomienda PowerShell Core 7+ (pwsh)."
    }

    # 2. uv (Astral)
    $uvExe = Find-UvExecutable
    if ($uvExe) {
        try {
            $uvVersionOutput = & $uvExe --version 2>&1
            Write-Success "uv (Astral): $uvVersionOutput ($uvExe)"
        } catch {
            Write-Success "uv (Astral) encontrado en: $uvExe"
        }
    } else {
        $allOk = $false
        Write-WarningMsg "No se encontro el ejecutable 'uv' en PATH ni en las rutas estandar."

        if ($DryRun) {
            Write-Info "Para instalarlo ejecuta: winget install --id astral-sh.uv -e"
        } else {
            $response = Read-Host "Deseas instalar 'uv' ahora mismo mediante WinGet? (S/n)"
            if ($response -eq "" -or $response -match '^[sSyY]') {
                Write-Info "Instalando uv con winget..."
                $wingetProcess = Start-Process -FilePath "winget" -ArgumentList "install --id astral-sh.uv -e --accept-source-agreements --accept-package-agreements" -NoNewWindow -Wait -PassThru
                if ($wingetProcess.ExitCode -eq 0) {
                    Update-SessionPath
                    $uvExe = Find-UvExecutable
                    if ($uvExe) {
                        Write-Success "uv instalado correctamente: $uvExe"
                        $allOk = $true
                    } else {
                        Write-WarningMsg "uv se instalo pero requiere reiniciar la terminal para actualizar el PATH."
                    }
                } else {
                    Write-ErrorMsg "Error al ejecutar winget para instalar uv."
                }
            } else {
                Write-Info "Instalacion omitida por el usuario."
            }
        }
    }

    # 3. Git
    $gitExe = Find-GitExecutable
    if ($gitExe) {
        try {
            $gitVersionOutput = & $gitExe --version 2>&1
            Write-Success "Git: $gitVersionOutput ($gitExe)"
        } catch {
            Write-Success "Git encontrado en: $gitExe"
        }
    } else {
        $allOk = $false
        Write-WarningMsg "No se encontro Git en el sistema."

        if ($DryRun) {
            Write-Info "Para instalarlo ejecuta: winget install --id Git.Git -e"
        } else {
            $response = Read-Host "Deseas instalar 'Git' ahora mismo mediante WinGet? (S/n)"
            if ($response -eq "" -or $response -match '^[sSyY]') {
                Write-Info "Instalando Git con winget..."
                $wingetProcess = Start-Process -FilePath "winget" -ArgumentList "install --id Git.Git -e --accept-source-agreements --accept-package-agreements" -NoNewWindow -Wait -PassThru
                if ($wingetProcess.ExitCode -eq 0) {
                    Update-SessionPath
                    $gitExe = Find-GitExecutable
                    if ($gitExe) {
                        Write-Success "Git instalado correctamente: $gitExe"
                        $allOk = $true
                    } else {
                        Write-WarningMsg "Git se instalo pero requiere reiniciar la terminal para actualizar el PATH."
                    }
                } else {
                    Write-ErrorMsg "Error al ejecutar winget para instalar Git."
                }
            } else {
                Write-Info "Instalacion de Git omitida por el usuario."
            }
        }
    }

    # 4. Conectividad basica a repositorios
    Write-Info "Verificando conectividad a servicios requeridos..."
    $services = @{
        "GitHub" = "https://github.com"
        "PyPI"   = "https://pypi.org"
    }

    foreach ($name in $services.Keys) {
        $url = $services[$name]
        try {
            Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 5 -ErrorAction Stop | Out-Null
            Write-Success "Conectividad $($name): OK"
        } catch {
            Write-WarningMsg "No se pudo contactar $name ($url): $($_.Exception.Message)"
        }
    }

    Write-Host ""
    if ($allOk) {
        Write-Success "Todas las dependencias previas estan listas. Puedes continuar con 'comodo.ps1 probe'."
    } else {
        Write-WarningMsg "Faltan dependencias para operar con normalidad. Revisa los mensajes anteriores."
    }

    return $allOk
}

Export-ModuleMember -Function 'Invoke-PreRequisites'
