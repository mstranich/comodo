<#
.SYNOPSIS
    comfy.ps1 - Alias de comodo.ps1.
.DESCRIPTION
    Permite invocar todas las capacidades del gestor con .\comfy.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ArgsList
)

$targetScript = Join-Path $PSScriptRoot "comodo.ps1"

$allArgs = @($Command)
if ($ArgsList) { $allArgs += $ArgsList }

& $targetScript @allArgs
# Propagar el codigo de salida para que el alias sea equivalente al original.
exit $LASTEXITCODE
