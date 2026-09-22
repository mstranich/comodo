<#
.SYNOPSIS
    Ejecuta el control de calidad del repositorio: PSScriptAnalyzer, Pester y pytest.
.DESCRIPTION
    Pensado para correr igual en local y en CI. Los modulos de PowerShell se
    buscan primero en .psmodules/ del propio repositorio, para no depender de
    lo que haya instalado en el perfil del usuario (que en Windows suele estar
    sincronizado por OneDrive y da problemas de instalacion).
.EXAMPLE
    pwsh -File tests/Invoke-Checks.ps1
    pwsh -File tests/Invoke-Checks.ps1 -SkipPython
#>

[CmdletBinding()]
param(
    [switch]$SkipPython,
    [switch]$SkipLint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path $PSScriptRoot -Parent

# Modulos locales del repo, si existen, con prioridad sobre los del sistema.
$localModules = Join-Path $RepoRoot '.psmodules'
if (Test-Path -LiteralPath $localModules) {
    $env:PSModulePath = $localModules + [IO.Path]::PathSeparator + $env:PSModulePath
}

$failures = @()

# --- 1. Analisis estatico -----------------------------------------------------
if (-not $SkipLint) {
    Write-Host "`n=== PSScriptAnalyzer ===" -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-Host "PSScriptAnalyzer no disponible; se omite." -ForegroundColor Yellow
    }
    else {
        Import-Module PSScriptAnalyzer -Force
        # El filtro se aplica sobre la ruta RELATIVA a la raiz. Usar la ruta
        # absoluta seria un error: la raiz del repo puede llamarse ComfyUI
        # (D:\Apps\ComfyUI), y entonces el patron que excluye el ComfyUI
        # clonado excluiria tambien todos los archivos del propio gestor.
        $excluded = @('.psmodules', '.venv', 'ComfyUI')
        $targets = @(Get-ChildItem -Path $RepoRoot -Include '*.ps1', '*.psm1' -Recurse -File |
            Where-Object {
                $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
                $top = ($rel -split '[\\/]')[0]
                $top -notin $excluded
            })

        if ($targets.Count -eq 0) {
            throw "No se encontro ningun archivo que analizar bajo $RepoRoot"
        }

        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        # -Path acepta una sola ruta, asi que se analiza archivo por archivo.
        $issues = @($targets | ForEach-Object {
            Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings
        })

        if ($issues.Count -eq 0) {
            Write-Host "Sin hallazgos en $($targets.Count) archivos." -ForegroundColor Green
        }
        else {
            $issues | ForEach-Object {
                $color = if ($_.Severity -eq 'Error') { 'Red' } else { 'Yellow' }
                Write-Host ("[{0}] {1}:{2} {3}" -f $_.Severity, (Split-Path $_.ScriptName -Leaf), $_.Line, $_.RuleName) -ForegroundColor $color
                Write-Host ("        " + $_.Message) -ForegroundColor DarkGray
            }
            if (@($issues | Where-Object { $_.Severity -in @('Error', 'Warning') }).Count -gt 0) {
                $failures += "PSScriptAnalyzer: $($issues.Count) hallazgo(s)"
            }
        }
    }
}

# --- 2. Pester ----------------------------------------------------------------
Write-Host "`n=== Pester ===" -ForegroundColor Cyan
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    Write-Host "Pester 5+ no disponible (encontrado: $(if ($pester) { $pester.Version } else { 'ninguno' })); se omite." -ForegroundColor Yellow
}
else {
    Import-Module Pester -MinimumVersion 5.0 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $PSScriptRoot
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Normal'
    $result = Invoke-Pester -Configuration $cfg
    if ($result.FailedCount -gt 0) {
        $failures += "Pester: $($result.FailedCount) prueba(s) fallida(s)"
    }
}

# --- 3. pytest ----------------------------------------------------------------
if (-not $SkipPython) {
    Write-Host "`n=== pytest ===" -ForegroundColor Cyan
    $pyExe = Join-Path $RepoRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pyExe)) { $pyExe = 'python' }

    & $pyExe -m pytest (Join-Path $PSScriptRoot 'test_probe_hardware.py') -q
    if ($LASTEXITCODE -ne 0) {
        $failures += "pytest: fallos"
    }
}

# --- 4. Coherencia del lock ---------------------------------------------------
Write-Host "`n=== uv lock --check ===" -ForegroundColor Cyan
$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) {
    Write-Host "uv no disponible; se omite." -ForegroundColor Yellow
}
else {
    # Garantiza que uv.lock corresponde a pyproject.toml: si no, 'setup'
    # fallaria en el usuario final porque usa 'uv sync --locked'.
    & $uv.Source lock --check --project $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        $failures += "uv.lock desactualizado respecto a pyproject.toml (ejecuta: uv lock)"
    }
    else {
        Write-Host "uv.lock coherente con pyproject.toml." -ForegroundColor Green
    }
}

# --- Resultado ----------------------------------------------------------------
Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "TODO OK" -ForegroundColor Green
    exit 0
}
Write-Host "FALLOS:" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
