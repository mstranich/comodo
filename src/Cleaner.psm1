# ==============================================================================
# Cleaner.psm1 - Limpieza y Restablecimiento Completo (reset / uninstall)
# ==============================================================================

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Config.psm1") -DisableNameChecking

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

    # Verificar confirmación si no viene -Force
    if (-not $Force) {
        Write-Host ""
        Write-WarningMsg "Esta acción eliminará los siguientes componentes para volver a empezar:"
        if (Test-Path -LiteralPath $venvDir) {
            Write-Host "  - Entorno virtual de Python (.venv)" -ForegroundColor Yellow
        }
        if (Test-Path -LiteralPath $comfyDir) {
            Write-Host "  - Instalación de ComfyUI y todos los nodos clonados (ComfyUI/)" -ForegroundColor Yellow
        }
        if (-not $KeepConfig -and (Test-Path -LiteralPath $cfgPath)) {
            Write-Host "  - Archivo de configuración local (etc/config.json)" -ForegroundColor Yellow
        }
        if ($KeepModels) {
            Write-Host "  * Modelos en ComfyUI/models serán preservados." -ForegroundColor Cyan
        }
        Write-Host ""
        $answer = Read-Host "¿Estás seguro de que deseas continuar con el restablecimiento? (s/N)"
        if ($answer -notmatch '^(s|si|y|yes)$') {
            Write-Info "Operación cancelada por el usuario."
            return $false
        }
    }

    # 1. Detener procesos huérfanos de ComfyUI o Python dentro de .venv si los hubiera
    Write-Info "Comprobando procesos en ejecución..."
    try {
        Get-Process -Name "python" -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path.StartsWith($rootDir, [System.StringComparison]::OrdinalIgnoreCase)
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }

    # 2. Respaldar modelos si se solicitó -KeepModels
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

    # Restaurar modelos si correspondía
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

    # 5. Eliminar configuración local etc/config.json si no se indicó -KeepConfig
    if (-not $KeepConfig -and (Test-Path -LiteralPath $cfgPath)) {
        Write-Info "Eliminando configuración local etc/config.json..."
        Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
        Write-Success "Archivo etc/config.json eliminado (se restablecerá en el próximo setup o probe)."
    }

    Write-Banner "[OK] Restablecimiento completado." -Level Success
    Write-Info "Para aprovisionar de nuevo, ejecuta: .\comodo.ps1 setup"
    return $true
}

Export-ModuleMember -Function 'Invoke-ComfyReset'
