<#
.SYNOPSIS
    comodo.ps1 - Gestor de ComfyUI para Windows.
.DESCRIPTION
    Gestor en PowerShell Core que automatiza la verificacion de requisitos, la
    deteccion de hardware, el aprovisionamiento con uv y la gestion de nodos.
    El perfil de aceleracion se deriva de la GPU detectada en cada maquina.
.EXAMPLE
    .\comodo.ps1 pre-requisites --dry
    .\comodo.ps1 probe
    .\comodo.ps1 setup
    .\comodo.ps1 start --lowvram
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ArgsList
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$srcDir = Join-Path $PSScriptRoot "src"
foreach ($mod in @('Common','Config','Checker','Probe','Installer','Runner','Updater','Doctor','Nodes','Cleaner')) {
    Import-Module (Join-Path $srcDir "$mod.psm1") -Force
}

$ArgsList = @($ArgsList)

function Test-Flag {
    <#
    .SYNOPSIS
        Busca un flag admitiendo las formas --nombre y -nombre.
    #>
    param([string[]]$Names)
    foreach ($n in $Names) {
        if ($ArgsList -contains "--$n" -or $ArgsList -contains "-$n") { return $true }
    }
    return $false
}

function Get-OptionValue {
    <#
    .SYNOPSIS
        Devuelve el valor que sigue a --nombre / -nombre, o $null.
    #>
    param([string]$Name)
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        if ($ArgsList[$i] -in @("--$Name", "-$Name")) {
            if (($i + 1) -lt $ArgsList.Count) { return $ArgsList[$i + 1] }
            Write-ErrorMsg "La opcion '--$Name' requiere un valor."
            return $null
        }
    }
    return $null
}

function Show-Help {
    $sep = "=" * 66
    Write-Host "`n$ColorBold$ColorCyan$sep`n Comodo - gestor de ComfyUI (comodo.ps1)`n$sep$ColorReset"
    Write-Host "Uso: .\comodo.ps1 <subcomando> [opciones]`n" -ForegroundColor DarkCyan

    Write-Host "$ColorBold[COMANDOS]$ColorReset"
    Write-Host "  $ColorYellow pre-requisites $ColorReset (prereqs, check)"
    Write-Host "      Verifica pwsh, uv, git y conectividad."
    Write-Host "      Opciones: --dry`n"

    Write-Host "  $ColorYellow probe $ColorReset (detect, hardware)"
    Write-Host "      Detecta la GPU y calcula el perfil optimo para esta maquina."
    Write-Host "      Opciones: --show (no guarda cambios)`n"

    Write-Host "  $ColorYellow setup $ColorReset (download, install)"
    Write-Host "      Clona ComfyUI, crea el venv con uv e instala PyTorch y los"
    Write-Host "      aceleradores que soporte la GPU detectada."
    Write-Host "      Opciones: --force, --cuda <ver>, --skip-opt, --skip-nodes, --allow-cpu`n"

    Write-Host "  $ColorYellow start $ColorReset (run)"
    Write-Host "      Inicia ComfyUI con la configuracion guardada."
    Write-Host "      Opciones: --lowvram, --highvram, --no-sage, --listen <ip>, --port <n>`n"

    Write-Host "  $ColorYellow set <clave> [valor]$ColorReset / $ColorYellow unset <clave>$ColorReset"
    Write-Host "      Ajustes persistentes: lowvram, highvram, port, listen, sage,"
    Write-Host "      triton, cuda, python, preview.`n"

    Write-Host "  $ColorYellow config $ColorReset (get)        Muestra la configuracion activa.`n"

    Write-Host "  $ColorYellow custom-nodes <list|add|remove>$ColorReset (nodes)"
    Write-Host "      Gestiona nodos. Solo ComfyUI-Manager viene preinstalado.`n"

    Write-Host "  $ColorYellow upgrade $ColorReset (update)     Actualiza ComfyUI, nodos y aceleradores."
    Write-Host "  $ColorYellow doctor $ColorReset               Comprueba el entorno contra el perfil detectado."
    Write-Host "  $ColorYellow reset $ColorReset (uninstall)    Limpia .venv, la instalacion y la config local."
    Write-Host "      Opciones: --force (-y), --keep-models, --keep-config`n"

    Write-Host "$ColorBold[EJEMPLOS]$ColorReset"
    Write-Host "  .\comodo.ps1 pre-requisites --dry"
    Write-Host "  .\comodo.ps1 probe"
    Write-Host "  .\comodo.ps1 setup"
    Write-Host "  .\comodo.ps1 start"
    Write-Host "  .\comodo.ps1 nodes add https://github.com/user/mi-nodo.git"
    Write-Host "  .\comodo.ps1 set port 8189`n"
}

# El codigo de salida refleja el resultado real, para poder encadenar comandos
# y usar el gestor desde scripts o CI.
$ok = $true

try {
    switch -Regex ($Command.ToLower()) {

        '^(pre-requisites|prereqs|check)$' {
            $ok = Invoke-PreRequisites -DryRun:(Test-Flag @('dry','dryrun'))
        }

        '^(probe|detect|hardware)$' {
            $ok = ($null -ne (Invoke-HardwareProbe -ShowOnly:(Test-Flag @('show'))))
        }

        '^(setup|download|install)$' {
            $cuda = Get-OptionValue 'cuda'
            $ok = Invoke-ComfySetup `
                -Force:(Test-Flag @('force')) `
                -CudaVersion:$cuda `
                -SkipOptimizations:(Test-Flag @('skip-opt','skip-optimizations')) `
                -SkipNodes:(Test-Flag @('skip-nodes')) `
                -AllowCpu:(Test-Flag @('allow-cpu','cpu'))
        }

        '^(start|run)$' {
            $listen = Get-OptionValue 'listen'
            $portRaw = Get-OptionValue 'port'
            $port = 0
            if ($portRaw) {
                # Validar en vez de castear: un [int] sobre basura lanzaba una
                # excepcion cruda en la cara del usuario.
                $parsed = 0
                if (-not [int]::TryParse($portRaw, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
                    Write-ErrorMsg "Puerto invalido: '$portRaw'. Debe ser un entero entre 1 y 65535."
                    exit 2
                }
                $port = $parsed
            }

            # Todo lo que no sea un flag conocido ni el valor de una opcion se
            # reenvia a main.py tal cual.
            $known = @('--lowvram','-lowvram','--highvram','-highvram','--no-sage','-no-sage')
            $extra = @()
            for ($i = 0; $i -lt $ArgsList.Count; $i++) {
                $a = $ArgsList[$i]
                if ($a -in @('--listen','-listen','--port','-port')) { $i++; continue }
                if ($a -in $known) { continue }
                $extra += $a
            }

            $ok = Start-Comfy `
                -LowVRam:(Test-Flag @('lowvram')) `
                -HighVRam:(Test-Flag @('highvram')) `
                -NoSage:(Test-Flag @('no-sage')) `
                -Listen:$listen -Port:$port -ExtraArgs:$extra
        }

        '^(set)$' {
            if ($ArgsList.Count -lt 1) {
                Write-ErrorMsg "Uso: .\comodo.ps1 set <clave> [valor]"
                exit 2
            }
            $ok = Set-ComfyConfigProperty -Key $ArgsList[0] -Value $(if ($ArgsList.Count -gt 1) { $ArgsList[1] } else { $null })
        }

        '^(unset|rm)$' {
            if ($ArgsList.Count -lt 1) {
                Write-ErrorMsg "Uso: .\comodo.ps1 unset <clave>"
                exit 2
            }
            $ok = Reset-ComfyConfigProperty -Key $ArgsList[0]
        }

        '^(custom-nodes|custom-node|nodes|node)$' {
            $sub = if ($ArgsList.Count -gt 0) { $ArgsList[0].ToLower() } else { "list" }
            switch -Regex ($sub) {
                '^(list|ls)$' { $ok = Show-CustomNodesList }
                '^(add|clone|install)$' {
                    if ($ArgsList.Count -lt 2) {
                        Write-ErrorMsg "Uso: .\comodo.ps1 custom-nodes add <url_git> [nombre]"
                        exit 2
                    }
                    $name = if ($ArgsList.Count -gt 2 -and $ArgsList[2] -notmatch '^-') { $ArgsList[2] } else { $null }
                    $ok = Add-CustomNode -Url $ArgsList[1] -Name $name
                }
                '^(remove|rm|delete)$' {
                    if ($ArgsList.Count -lt 2) {
                        Write-ErrorMsg "Uso: .\comodo.ps1 custom-nodes remove <nombre>"
                        exit 2
                    }
                    $ok = Remove-CustomNode -Name $ArgsList[1] -Force:(Test-Flag @('force','f'))
                }
                default {
                    Write-ErrorMsg "Subcomando no reconocido: '$sub'. Usa: list, add, remove."
                    exit 2
                }
            }
        }

        '^(config|get)$'      { Show-ComfyConfig }

        '^(upgrade|update)$'  {
            $ok = Invoke-ComfyUpgrade -CoreOnly:(Test-Flag @('core-only')) -NodesOnly:(Test-Flag @('nodes-only'))
        }

        '^(doctor)$'          { $ok = Invoke-ComfyDoctor }

        '^(reset|uninstall)$' {
            $ok = Invoke-ComfyReset `
                -Force:(Test-Flag @('force','y','f')) `
                -KeepConfig:(Test-Flag @('keep-config')) `
                -KeepModels:(Test-Flag @('keep-models'))
        }

        '^(help|--help|-h|/\?)$' { Show-Help }

        default {
            Write-ErrorMsg "Comando desconocido: '$Command'"
            Show-Help
            exit 2
        }
    }
}
catch {
    Write-ErrorMsg "$_"
    exit 1
}

if ($ok -is [bool] -and -not $ok) { exit 1 }
exit 0
