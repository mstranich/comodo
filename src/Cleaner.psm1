# ==============================================================================
# Cleaner.psm1 - Limpieza y Restablecimiento Completo (reset / uninstall)
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")
Import-Module (Join-Path $PSScriptRoot "Config.psm1")

function Invoke-ComfyReset {
    [CmdletBinding()]
    param(
        [switch]$Force = $false,
        [switch]$KeepConfig = $false,
        [switch]$KeepModels = $false
    )

    $rootDir = Get-ProjectRoot
    Write-StepHeader "Restablecimiento y Limpieza Completa (reset / uninstall)"

    $venvDir = Join-Path $rootDir ".venv"
    $config   = Get-ComfyConfig
    $comfyDir = Join-Path $rootDir $config.install.install_dir
    $cfgPath = Join-Path $rootDir "etc\config.json"

    # Verificar confirmacion si no viene -Force
    if (-not $Force) {
        Write-Host ""
        Write-WarningMsg "Esta accion eliminara los siguientes componentes para volver a empezar:"
        if (Test-Path -LiteralPath $venvDir) {
            Write-Host "  - Entorno virtual de Python (.venv)" -ForegroundColor Yellow
        }
        if (Test-Path -LiteralPath $comfyDir) {
            Write-Host "  - Instalacion de ComfyUI y todos los nodos clonados (ComfyUI/)" -ForegroundColor Yellow
        }
        if (-not $KeepConfig -and (Test-Path -LiteralPath $cfgPath)) {
            Write-Host "  - Archivo de configuracion local (etc/config.json)" -ForegroundColor Yellow
        }
        if ($KeepModels) {
            Write-Host "  * Modelos en ComfyUI/models seran preservados." -ForegroundColor Cyan
        }
        Write-Host ""
        $answer = Read-Host "Estas seguro de que deseas continuar con el restablecimiento? (s/N)"
        if ($answer -notmatch '^(s|si|y|yes)$') {
            Write-Info "Operacion cancelada por el usuario."
            return $false
        }
    }

    # 1. Detener procesos de ComfyUI que sigan vivos.
    #
    # No basta con filtrar por la ruta del ejecutable: cuando uv crea el venv,
    # .venv\Scripts\python.exe es solo un trampolin y el proceso real corre
    # bajo el interprete base de uv (en %APPDATA%\uv\python\...). Filtrar por
    # Path dejaba vivo justo al proceso que mantiene bloqueados los archivos
    # de .venv y ComfyUI, y el borrado fallaba de forma intermitente.
    # Por eso se busca en la linea de comandos, que si referencia el proyecto.
    Write-Info "Comprobando procesos en ejecucion..."
    try {
        $targets = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.CommandLine -and $_.CommandLine -like "*$rootDir*") -or
                ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($rootDir, [System.StringComparison]::OrdinalIgnoreCase))
            })

        if ($targets.Count -gt 0) {
            Write-Info "Deteniendo $($targets.Count) proceso(s) de ComfyUI..."
            foreach ($t in $targets) {
                Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue
            }
            # Dar tiempo a que Windows libere los descriptores antes de borrar.
            Start-Sleep -Milliseconds 800
        }
    } catch {
        Write-WarningMsg "No se pudieron enumerar los procesos: $_"
    }

    # 2. Respaldar modelos si se solicito -KeepModels
    $tempModelsDir = Join-Path $rootDir "models_backup_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $modelsMoved = $false
    if ($KeepModels -and (Test-Path -LiteralPath (Join-Path $comfyDir "models"))) {
        Write-Info "Preservando modelos en: $(Split-Path $tempModelsDir -Leaf)"
        try {
            Move-Item -LiteralPath (Join-Path $comfyDir "models") -Destination $tempModelsDir -Force -ErrorAction Stop
            $modelsMoved = $true
        } catch {
            # Abortar antes de borrar nada: perder los modelos es el peor
            # resultado posible de este comando.
            Write-ErrorMsg "No se pudieron preservar los modelos: $_"
            Write-ErrorMsg "Se aborta el reset para no perderlos."
            return $false
        }
    }

    # 3. Eliminar entorno virtual (.venv)
    if (Test-Path -LiteralPath $venvDir) {
        Write-Info "Eliminando entorno virtual (.venv)..."
        Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $venvDir) {
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Success "Entorno virtual .venv eliminado."
    }

    # 4. Eliminar directorio ComfyUI
    if (Test-Path -LiteralPath $comfyDir) {
        Write-Info "Eliminando directorio ComfyUI..."
        Remove-Item -LiteralPath $comfyDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $comfyDir) {
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath $comfyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Success "Directorio ComfyUI eliminado."
    }

    # Restaurar modelos si correspondia
    if ($modelsMoved -and (Test-Path -LiteralPath $tempModelsDir)) {
        $newModels = Join-Path $comfyDir "models"
        New-Item -ItemType Directory -Path $comfyDir -Force | Out-Null
        try {
            Move-Item -LiteralPath $tempModelsDir -Destination $newModels -Force -ErrorAction Stop
            Write-Success "Modelos restaurados en $($config.install.install_dir)/models."
        } catch {
            # Nunca dejar al usuario sin saber donde quedaron sus modelos.
            Write-ErrorMsg "No se pudieron restaurar los modelos automaticamente."
            Write-WarningMsg "Siguen intactos en: $tempModelsDir"
        }
    }

    # 5. Eliminar configuracion local etc/config.json si no se indico -KeepConfig
    if (-not $KeepConfig -and (Test-Path -LiteralPath $cfgPath)) {
        Write-Info "Eliminando configuracion local etc/config.json..."
        Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
        Write-Success "Archivo etc/config.json eliminado (se restablecera en el proximo setup o probe)."
    }

    Write-Banner "[OK] Restablecimiento completado." -Level Success
    Write-Info "Para aprovisionar de nuevo, ejecuta: .\comodo.ps1 setup"
    return $true
}

Export-ModuleMember -Function 'Invoke-ComfyReset'
