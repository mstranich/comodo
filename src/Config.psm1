# ==============================================================================
# Config.psm1 - Configuracion persistente en etc/config.json
# ==============================================================================

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Common.psm1")

# Unico nodo preinstalado: el gestor de nodos. Todo lo demas lo elige el usuario.
$script:DefaultCustomNodes = @(
    [PSCustomObject]@{
        name    = "ComfyUI-Manager"
        url     = "https://github.com/Comfy-Org/ComfyUI-Manager.git"
        enabled = $true
    }
)

function Get-ConfigFilePath {
    $etcDir = Join-Path (Get-ProjectRoot) "etc"
    if (-not (Test-Path -LiteralPath $etcDir)) {
        New-Item -ItemType Directory -Path $etcDir -Force | Out-Null
    }
    return (Join-Path $etcDir "config.json")
}

function New-DefaultConfig {
    <#
    .SYNOPSIS
        Configuracion base agnostica: sin hardware asumido.
    .DESCRIPTION
        Todos los campos de hardware quedan en $null a proposito. Es 'probe'
        quien los rellena con lo que realmente haya en la maquina. Inventar
        valores aqui produciria una configuracion que miente sobre el equipo.
    #>
    return [PSCustomObject]@{
        hardware = [PSCustomObject]@{
            vendor           = $null
            model            = $null
            vram_gb          = $null
            cuda_compute     = $null
            arch             = $null
            profile          = "unknown"
            accelerator      = $null
            detection_source = "none"
        }
        install = [PSCustomObject]@{
            method          = "uv"
            cuda_version    = $null
            torch_index_url = $null
            python_version  = "3.12"
            comfy_repo      = "https://github.com/comfyanonymous/ComfyUI.git"
            install_dir     = "ComfyUI"
        }
        optimizations = [PSCustomObject]@{
            triton         = $false
            sage_attention = $false
        }
        runtime = [PSCustomObject]@{
            lowvram        = $false
            highvram       = $false
            sage_attention = $false
            preview_method = "auto"
            listen         = "127.0.0.1"
            port           = 8188
            extra_args     = @()
        }
        custom_nodes = $script:DefaultCustomNodes
    }
}

function Set-DefaultMember {
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default
    )
    # Se consulta el indexador en vez de '.Properties.Name -notcontains': con
    # Set-StrictMode, leer .Name sobre una coleccion de propiedades vacia
    # (un [PSCustomObject]@{} recien creado) lanza excepcion.
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Default
    }
}

function ConvertTo-NormalizedConfig {
    <#
    .SYNOPSIS
        Garantiza que el objeto tenga el esquema completo.
    .DESCRIPTION
        Permite que un config.json antiguo (o recortado a mano) siga sirviendo:
        se le agregan las claves nuevas sin tocar las que el usuario ya definio.
    #>
    param([Parameter(Mandatory=$true)][PSCustomObject]$Config)

    $defaults = New-DefaultConfig

    foreach ($section in @('hardware','install','optimizations','runtime')) {
        Set-DefaultMember -Object $Config -Name $section -Default ([PSCustomObject]@{})
        foreach ($prop in $defaults.$section.PSObject.Properties) {
            Set-DefaultMember -Object $Config.$section -Name $prop.Name -Default $prop.Value
        }
    }
    Set-DefaultMember -Object $Config -Name 'custom_nodes' -Default $defaults.custom_nodes

    return $Config
}

function Get-ComfyConfig {
    [CmdletBinding()]
    param()

    $cfgPath = Get-ConfigFilePath

    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8
            return (ConvertTo-NormalizedConfig -Config ($raw | ConvertFrom-Json))
        }
        catch {
            # No sobrescribir a ciegas: preservar el archivo ilegible para que
            # el usuario pueda recuperar lo que tuviera configurado.
            $backup = "$cfgPath.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            try {
                Move-Item -LiteralPath $cfgPath -Destination $backup -Force
                Write-WarningMsg "etc/config.json ilegible. Respaldado en: $(Split-Path $backup -Leaf)"
            } catch {
                Write-ErrorMsg "etc/config.json ilegible y no se pudo respaldar: $_"
            }
        }
    }

    $examplePath = Join-Path (Split-Path $cfgPath -Parent) "config.example.json"
    if (Test-Path -LiteralPath $examplePath) {
        try {
            $raw = Get-Content -Path $examplePath -Raw -Encoding UTF8
            $fromExample = ConvertTo-NormalizedConfig -Config ($raw | ConvertFrom-Json)
            Save-ComfyConfig -Config $fromExample
            return $fromExample
        }
        catch {
            Write-WarningMsg "No se pudo leer etc/config.example.json. Generando configuracion base."
        }
    }

    $defaultConfig = New-DefaultConfig
    Save-ComfyConfig -Config $defaultConfig
    return $defaultConfig
}

function Save-ComfyConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][PSCustomObject]$Config)

    $cfgPath = Get-ConfigFilePath
    # ConvertTo-Json serializa '$comment' si viene de la plantilla; es inocuo.
    $json = $Config | ConvertTo-Json -Depth 10
    Set-Content -Path $cfgPath -Value $json -Encoding UTF8
}

function Set-ComfyConfigProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Key,
        [Parameter(Position=1)][AllowNull()][string]$Value = $null
    )

    $config = Get-ComfyConfig
    $keyLower = $Key.ToLower()

    if ([string]::IsNullOrEmpty($Value)) {
        $valObj = $true
    }
    elseif ($Value -in @("true","1","yes","on","si"))   { $valObj = $true }
    elseif ($Value -in @("false","0","no","off"))       { $valObj = $false }
    elseif ($Value -match '^\d+$')                      { $valObj = [int]$Value }
    else                                                { $valObj = $Value }

    switch -Regex ($keyLower) {
        '^(lowvram|low-vram)$' {
            $config.runtime.lowvram = [bool]$valObj
            # lowvram y highvram son mutuamente excluyentes: activar uno apaga el otro
            # en vez de dejar un estado ambiguo que el runner resolveria en silencio.
            if ($config.runtime.lowvram) { $config.runtime.highvram = $false }
            Write-Success "runtime.lowvram = $($config.runtime.lowvram)"
        }
        '^(highvram|high-vram)$' {
            $config.runtime.highvram = [bool]$valObj
            if ($config.runtime.highvram) { $config.runtime.lowvram = $false }
            Write-Success "runtime.highvram = $($config.runtime.highvram)"
        }
        '^(port|puerto)$' {
            if ($valObj -isnot [int] -or $valObj -lt 1 -or $valObj -gt 65535) {
                Write-ErrorMsg "Puerto invalido: '$Value'. Debe ser un entero entre 1 y 65535."
                return $false
            }
            $config.runtime.port = [int]$valObj
            Write-Success "runtime.port = $($config.runtime.port)"
        }
        '^(listen|host|ip)$' {
            $config.runtime.listen = [string]$valObj
            if ($config.runtime.listen -eq "0.0.0.0") {
                Write-WarningMsg "listen=0.0.0.0 expone ComfyUI a toda la red local, sin autenticacion."
            }
            Write-Success "runtime.listen = $($config.runtime.listen)"
        }
        '^(sage|sage_attention|sageattention)$' {
            $config.runtime.sage_attention = [bool]$valObj
            $config.optimizations.sage_attention = [bool]$valObj
            Write-Success "sage_attention = $($config.runtime.sage_attention)"
        }
        '^(triton)$' {
            $config.optimizations.triton = [bool]$valObj
            Write-Success "optimizations.triton = $($config.optimizations.triton)"
        }
        '^(cuda|cuda_version)$' {
            $requested = [string]$valObj
            if (-not (Test-CudaVersionSupported -Version $requested)) {
                Write-ErrorMsg "Version de CUDA no soportada: '$requested'."
                Write-Info "Valores validos: $((Get-SupportedCudaVersions) -join ', ')"
                return $false
            }
            $config.install.cuda_version = $requested
            $config.install.torch_index_url = Get-TorchIndexUrl -CudaVersion $requested
            Write-Success "install.cuda_version = $requested ($($config.install.torch_index_url))"
        }
        '^(python|python_version)$' {
            $config.install.python_version = [string]$valObj
            Write-Success "install.python_version = $($config.install.python_version)"
        }
        '^(preview|preview_method)$' {
            $valid = @('auto','latent2rgb','taesd','none')
            if ([string]$valObj -notin $valid) {
                Write-ErrorMsg "preview_method invalido: '$valObj'. Validos: $($valid -join ', ')"
                return $false
            }
            $config.runtime.preview_method = [string]$valObj
            Write-Success "runtime.preview_method = $($config.runtime.preview_method)"
        }
        default {
            Write-WarningMsg "Clave '$Key' no reconocida."
            Write-Info "Validas: lowvram, highvram, port, listen, sage, triton, cuda, python, preview."
            return $false
        }
    }

    Save-ComfyConfig -Config $config
    return $true
}

function Reset-ComfyConfigProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true, Position=0)][string]$Key)

    $config = Get-ComfyConfig
    $defaults = New-DefaultConfig
    $keyLower = $Key.ToLower()

    switch -Regex ($keyLower) {
        '^(lowvram|low-vram)$' {
            $config.runtime.lowvram = $false
            Write-Success "runtime.lowvram restablecido a: false"
        }
        '^(highvram|high-vram)$' {
            $config.runtime.highvram = $false
            Write-Success "runtime.highvram restablecido a: false"
        }
        '^(port|puerto)$' {
            $config.runtime.port = $defaults.runtime.port
            Write-Success "runtime.port restablecido a: $($config.runtime.port)"
        }
        '^(listen|host|ip)$' {
            $config.runtime.listen = $defaults.runtime.listen
            Write-Success "runtime.listen restablecido a: $($config.runtime.listen)"
        }
        '^(sage|sage_attention|sageattention)$' {
            # El valor de reposo depende del hardware detectado, no de una
            # preferencia fija: se recupera lo que decidio 'probe'.
            $detected = [bool]$config.optimizations.sage_attention
            $config.runtime.sage_attention = $detected
            Write-Success "runtime.sage_attention restablecido a lo detectado: $detected"
        }
        '^(triton)$' {
            Write-Info "optimizations.triton lo determina el hardware. Ejecuta 'probe' para recalcularlo."
            return $true
        }
        '^(preview|preview_method)$' {
            $config.runtime.preview_method = $defaults.runtime.preview_method
            Write-Success "runtime.preview_method restablecido a: $($config.runtime.preview_method)"
        }
        '^(extra_args|extraargs)$' {
            $config.runtime.extra_args = @()
            Write-Success "runtime.extra_args vaciado."
        }
        '^(all|todo|reset)$' {
            $config.runtime.lowvram        = $defaults.runtime.lowvram
            $config.runtime.highvram       = $defaults.runtime.highvram
            $config.runtime.sage_attention = [bool]$config.optimizations.sage_attention
            $config.runtime.preview_method = $defaults.runtime.preview_method
            $config.runtime.listen         = $defaults.runtime.listen
            $config.runtime.port           = $defaults.runtime.port
            $config.runtime.extra_args     = @()
            Write-Success "Parametros de runtime restablecidos a sus valores por defecto."
        }
        default {
            Write-WarningMsg "Clave '$Key' no reconocida para unset."
            Write-Info "Opciones: lowvram, highvram, port, listen, sage, preview, extra_args, all."
            return $false
        }
    }

    Save-ComfyConfig -Config $config
    return $true
}

function Format-ConfigValue {
    param($Value, [string]$Unknown = "no detectado")
    if ($null -eq $Value -or "$Value" -eq "") { return $Unknown }
    return "$Value"
}

function Show-ComfyConfig {
    [CmdletBinding()]
    param()

    $cfg = Get-ComfyConfig
    Write-StepHeader "Configuracion actual (etc/config.json)"

    Write-Host "`n  [Hardware]" -ForegroundColor DarkCyan
    Write-KeyVal "Fabricante"    (Format-ConfigValue $cfg.hardware.vendor)
    Write-KeyVal "Modelo"        (Format-ConfigValue $cfg.hardware.model)
    Write-KeyVal "VRAM"          $(if ($cfg.hardware.vram_gb) { "$($cfg.hardware.vram_gb) GB" } else { "no detectada" })
    Write-KeyVal "Arquitectura"  (Format-ConfigValue $cfg.hardware.arch)
    Write-KeyVal "Compute"       $(if ($cfg.hardware.cuda_compute) { "sm_$($cfg.hardware.cuda_compute)" } else { "no detectado" })
    Write-KeyVal "Perfil"        (Format-ConfigValue $cfg.hardware.profile)
    Write-KeyVal "Deteccion"     (Format-ConfigValue $cfg.hardware.detection_source "sin ejecutar probe")

    Write-Host "`n  [Instalacion]" -ForegroundColor DarkCyan
    Write-KeyVal "Metodo"        (Format-ConfigValue $cfg.install.method)
    Write-KeyVal "CUDA"          (Format-ConfigValue $cfg.install.cuda_version "sin definir (ejecuta probe)")
    Write-KeyVal "Indice PyTorch" (Format-ConfigValue $cfg.install.torch_index_url "sin definir")
    Write-KeyVal "Python"        (Format-ConfigValue $cfg.install.python_version)
    Write-KeyVal "Directorio"    (Format-ConfigValue $cfg.install.install_dir)

    Write-Host "`n  [Optimizaciones]" -ForegroundColor DarkCyan
    Write-KeyVal "Triton"         $(if ($cfg.optimizations.triton) { "habilitado" } else { "deshabilitado" })
    Write-KeyVal "SageAttention"  $(if ($cfg.optimizations.sage_attention) { "habilitado" } else { "deshabilitado" })

    Write-Host "`n  [Runtime]" -ForegroundColor DarkCyan
    $vramMode = if ($cfg.runtime.lowvram) { "lowvram" } elseif ($cfg.runtime.highvram) { "highvram" } else { "normal" }
    Write-KeyVal "Modo VRAM"      $vramMode
    Write-KeyVal "SageAttention"  $(if ($cfg.runtime.sage_attention) { "activo (--use-sage-attention)" } else { "inactivo" })
    Write-KeyVal "Preview"        (Format-ConfigValue $cfg.runtime.preview_method)
    Write-KeyVal "Listen"         (Format-ConfigValue $cfg.runtime.listen)
    Write-KeyVal "Puerto"         (Format-ConfigValue $cfg.runtime.port)

    Write-Host "`n  [Nodos registrados]" -ForegroundColor DarkCyan
    if (-not $cfg.custom_nodes -or @($cfg.custom_nodes).Count -eq 0) {
        Write-Host "    (ninguno)" -ForegroundColor DarkGray
    } else {
        foreach ($node in @($cfg.custom_nodes)) {
            $state = if ($node.enabled) { "" } else { " [deshabilitado]" }
            Write-KeyVal "$($node.name)$state" $node.url
        }
    }
    Write-Host ""
}

Export-ModuleMember -Function @(
    'Get-ComfyConfig',
    'Save-ComfyConfig',
    'New-DefaultConfig',
    'ConvertTo-NormalizedConfig',
    'Set-ComfyConfigProperty',
    'Reset-ComfyConfigProperty',
    'Show-ComfyConfig',
    'Format-ConfigValue'
)
