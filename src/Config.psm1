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
        # Lo rellena 'probe' a partir del registro de src/probe_hardware.py.
        # Vacio significa "todavia sin detectar", no "ninguno aplica".
        accelerators = @()
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

    foreach ($section in @('hardware','install','runtime')) {
        Set-DefaultMember -Object $Config -Name $section -Default ([PSCustomObject]@{})
        foreach ($prop in $defaults.$section.PSObject.Properties) {
            Set-DefaultMember -Object $Config.$section -Name $prop.Name -Default $prop.Value
        }
    }
    Set-DefaultMember -Object $Config -Name 'custom_nodes' -Default $defaults.custom_nodes
    Set-DefaultMember -Object $Config -Name 'accelerators' -Default @()

    # Migracion de configuraciones anteriores al registro de aceleradores.
    # La seccion 'optimizations' tenia una propiedad booleana por acelerador;
    # se conserva la eleccion del usuario y se descarta la seccion vieja.
    $legacy = $Config.PSObject.Properties['optimizations']
    if ($legacy -and @($Config.accelerators).Count -eq 0) {
        $migrated = @()
        foreach ($prop in $legacy.Value.PSObject.Properties) {
            $migrated += [PSCustomObject]@{
                key     = $prop.Name
                enabled = [bool]$prop.Value
                reason  = 'migrado de optimizations; ejecuta probe para recalcularlo'
            }
        }
        $Config.accelerators = $migrated
    }
    if ($legacy) { $Config.PSObject.Properties.Remove('optimizations') }

    return $Config
}

function Resolve-ComfyAcceleratorKey {
    <#
    .SYNOPSIS
        Traduce lo que escribio el usuario a una clave del registro.
    .DESCRIPTION
        Acepta la clave exacta, el nombre del paquete o del modulo, y un
        prefijo mientras sea inequivoco ('sage' -> 'sage_attention'). Se
        resuelve contra el registro y no contra una lista de alias escrita a
        mano, para que un acelerador nuevo funcione sin tocar este archivo.
    .OUTPUTS
        [string] la clave, o $null si no hay coincidencia unica.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Config,
        [Parameter(Mandatory=$true)][string]$Name
    )

    $needle = $Name.ToLower().Replace('-', '_')
    $all    = @($Config.accelerators)
    if ($all.Count -eq 0) { return $null }

    foreach ($a in $all) {
        if ($a.key.ToLower() -eq $needle) { return $a.key }
    }
    foreach ($a in $all) {
        foreach ($field in @('package', 'module')) {
            if ($a.PSObject.Properties[$field] -and
                "$($a.$field)".ToLower().Replace('-', '_') -eq $needle) {
                return $a.key
            }
        }
    }

    $prefix = @($all | Where-Object { $_.key.ToLower().StartsWith($needle) })
    if ($prefix.Count -eq 1) { return $prefix[0].key }

    return $null
}

function Get-ComfyAccelerator {
    <#
    .SYNOPSIS
        Devuelve la entrada del registro de aceleradores con esa clave, o $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Config,
        [Parameter(Mandatory=$true)][string]$Key
    )
    # Select-Object -First 1 en vez de [0]: con Set-StrictMode, indexar un
    # array vacio lanza "Index was outside the bounds of the array".
    return @($Config.accelerators | Where-Object { $_.key -eq $Key }) |
        Select-Object -First 1
}

function Test-ComfyAcceleratorEnabled {
    <#
    .SYNOPSIS
        Indica si un acelerador esta habilitado en el perfil detectado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Config,
        [Parameter(Mandatory=$true)][string]$Key
    )
    $accel = Get-ComfyAccelerator -Config $Config -Key $Key
    return ($null -ne $accel -and [bool]$accel.enabled)
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

# Reparto de claves por espacio de nombres. 'flag' son las que terminan
# siendo argumentos de main.py; 'provision' son decisiones de aprovisionamiento
# que nunca llegan a la linea de comandos de ComfyUI. Los aceleradores tienen
# su propio comando ('accel'), por eso no aparecen aqui.
$script:SettingScopes = @{
    flag = @(
        'lowvram', 'low-vram', 'highvram', 'high-vram',
        'listen', 'host', 'ip', 'port', 'puerto',
        'preview', 'preview_method', 'extra_args', 'extraargs'
    )
    provision = @(
        'cuda', 'cuda_version', 'python', 'python_version',
        'install_dir', 'dir', 'repo', 'comfy_repo'
    )
}

function Get-SettingScope {
    <#
    .SYNOPSIS
        Devuelve el espacio ('flag' o 'provision') al que pertenece una clave.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Key)

    $k = $Key.ToLower()
    foreach ($scope in $script:SettingScopes.Keys) {
        if ($script:SettingScopes[$scope] -contains $k) { return $scope }
    }
    return $null
}

function Assert-SettingScope {
    <#
    .SYNOPSIS
        Verifica que la clave corresponda al espacio invocado.
    .DESCRIPTION
        Si la clave existe pero en el otro espacio, se indica el comando
        correcto en vez de un "clave no reconocida" que no orienta.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('flag','provision')][string]$Scope,
        [Parameter(Mandatory=$true)][PSCustomObject]$Config,
        [Parameter(Mandatory=$true)][string]$Verb
    )

    $k = $Key.ToLower()

    # Los aceleradores viven en su propio comando.
    if (Resolve-ComfyAcceleratorKey -Config $Config -Name $k) {
        Write-ErrorMsg "'$Key' es un acelerador, no un ajuste de '$Scope'."
        Write-Info "Usa: .\comodo.ps1 accel <enable|disable> $k"
        return $false
    }

    $actual = Get-SettingScope -Key $k
    if (-not $actual) {
        Write-ErrorMsg "Clave no reconocida: '$Key'."
        Write-Info "Validas en '$Scope': $($script:SettingScopes[$Scope] -join ', ')"
        return $false
    }
    if ($actual -ne $Scope) {
        Write-ErrorMsg "'$Key' pertenece a '$actual', no a '$Scope'."
        Write-Info "Usa: .\comodo.ps1 $actual $Verb $k"
        return $false
    }
    return $true
}

function Set-ComfyConfigProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Key,
        [Parameter(Position=1)][AllowNull()][string]$Value = $null,
        [Parameter(Mandatory=$true)][ValidateSet('flag','provision')][string]$Scope
    )

    $config = Get-ComfyConfig
    if (-not (Assert-SettingScope -Key $Key -Scope $Scope -Config $config -Verb 'set')) {
        return $false
    }

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
            # lowvram y highvram son mutuamente excluyentes: activar uno apaga
            # el otro en vez de dejar un estado ambiguo.
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
            if ($config.runtime.listen -ne "127.0.0.1" -and $config.runtime.listen -ne "::1") {
                Write-WarningMsg "Escuchar fuera de loopback expone ComfyUI a la red, sin autenticacion."
                Write-WarningMsg "ComfyUI-Manager ademas bloquea la instalacion por URL Git si no es loopback."
            }
            Write-Success "runtime.listen = $($config.runtime.listen)"
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
        '^(extra_args|extraargs)$' {
            $config.runtime.extra_args = @([string]$valObj -split '\s+' | Where-Object { $_ })
            Write-Success "runtime.extra_args = $(@($config.runtime.extra_args) -join ' ')"
        }
        '^(cuda|cuda_version)$' {
            $requested = [string]$valObj
            if (-not (Test-CudaVersionSupported -Version $requested)) {
                Write-ErrorMsg "Version de CUDA no soportada: '$requested'."
                Write-Info "Valores validos: $((Get-SupportedCudaVersions) -join ', ')"
                return $false
            }
            $config.install.cuda_version    = $requested
            $config.install.torch_index_url = Get-TorchIndexUrl -CudaVersion $requested
            Write-Success "install.cuda_version = $requested ($($config.install.torch_index_url))"
        }
        '^(python|python_version)$' {
            $config.install.python_version = [string]$valObj
            Write-Success "install.python_version = $($config.install.python_version)"
        }
        '^(install_dir|dir)$' {
            $config.install.install_dir = [string]$valObj
            Write-Success "install.install_dir = $($config.install.install_dir)"
        }
        '^(repo|comfy_repo)$' {
            $config.install.comfy_repo = [string]$valObj
            Write-Success "install.comfy_repo = $($config.install.comfy_repo)"
        }
        default {
            Write-ErrorMsg "Clave sin implementacion: '$Key'."
            return $false
        }
    }

    Save-ComfyConfig -Config $config
    return $true
}

function Reset-ComfyConfigProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('flag','provision')][string]$Scope
    )

    $config   = Get-ComfyConfig
    $defaults = New-DefaultConfig
    $keyLower = $Key.ToLower()

    if ($Scope -eq 'flag' -and $keyLower -in @('all','todo')) {
        $config.runtime.lowvram        = $defaults.runtime.lowvram
        $config.runtime.highvram       = $defaults.runtime.highvram
        $config.runtime.preview_method = $defaults.runtime.preview_method
        $config.runtime.listen         = $defaults.runtime.listen
        $config.runtime.port           = $defaults.runtime.port
        $config.runtime.extra_args     = @()
        Save-ComfyConfig -Config $config
        Write-Success "Flags restablecidos a sus valores por defecto."
        return $true
    }

    if (-not (Assert-SettingScope -Key $Key -Scope $Scope -Config $config -Verb 'unset')) {
        return $false
    }

    switch -Regex ($keyLower) {
        '^(cuda|cuda_version)$' {
            # La version de CUDA la decide el hardware, no un valor fijo.
            Write-Info "La version de CUDA la determina el hardware."
            Write-Info "Ejecuta '.\comodo.ps1 probe' para recalcularla."
            return $true
        }
        '^(lowvram|low-vram)$'       { $config.runtime.lowvram = $defaults.runtime.lowvram }
        '^(highvram|high-vram)$'     { $config.runtime.highvram = $defaults.runtime.highvram }
        '^(port|puerto)$'            { $config.runtime.port = $defaults.runtime.port }
        '^(listen|host|ip)$'         { $config.runtime.listen = $defaults.runtime.listen }
        '^(preview|preview_method)$' { $config.runtime.preview_method = $defaults.runtime.preview_method }
        '^(extra_args|extraargs)$'   { $config.runtime.extra_args = @() }
        '^(python|python_version)$'  { $config.install.python_version = $defaults.install.python_version }
        '^(install_dir|dir)$'        { $config.install.install_dir = $defaults.install.install_dir }
        '^(repo|comfy_repo)$'        { $config.install.comfy_repo = $defaults.install.comfy_repo }
        default {
            Write-ErrorMsg "Clave sin implementacion: '$Key'."
            return $false
        }
    }

    Save-ComfyConfig -Config $config
    Write-Success "'$keyLower' restablecido a su valor por defecto."
    return $true
}

function Show-SettingScope {
    <#
    .SYNOPSIS
        Lista los ajustes de un espacio con su valor actual.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('flag','provision')][string]$Scope)

    $cfg = Get-ComfyConfig

    if ($Scope -eq 'flag') {
        Write-StepHeader "Flags de ejecucion (etc/config.json, llegan a main.py)"
        $vram = if ($cfg.runtime.lowvram) { "lowvram" } elseif ($cfg.runtime.highvram) { "highvram" } else { "normal" }
        Write-KeyVal "lowvram"     "$($cfg.runtime.lowvram)"
        Write-KeyVal "highvram"    "$($cfg.runtime.highvram)"
        Write-KeyVal "(modo VRAM)" $vram
        Write-KeyVal "listen"      (Format-ConfigValue $cfg.runtime.listen)
        Write-KeyVal "port"        (Format-ConfigValue $cfg.runtime.port)
        Write-KeyVal "preview"     (Format-ConfigValue $cfg.runtime.preview_method)
        Write-KeyVal "extra_args"  $(if (@($cfg.runtime.extra_args).Count -gt 0) { @($cfg.runtime.extra_args) -join ' ' } else { "(ninguno)" })
    }
    else {
        Write-StepHeader "Ajustes de aprovisionamiento (etc/config.json)"
        Write-KeyVal "cuda"        (Format-ConfigValue $cfg.install.cuda_version "sin definir (ejecuta probe)")
        Write-KeyVal "python"      (Format-ConfigValue $cfg.install.python_version)
        Write-KeyVal "install_dir" (Format-ConfigValue $cfg.install.install_dir)
        Write-KeyVal "repo"        (Format-ConfigValue $cfg.install.comfy_repo)
        Write-KeyVal "(indice)"    (Format-ConfigValue $cfg.install.torch_index_url "sin definir")
    }
    Write-Host ""
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

    Write-Host "`n  [Aceleradores]" -ForegroundColor DarkCyan
    if (@($cfg.accelerators).Count -eq 0) {
        Write-Host "    (sin detectar: ejecuta probe)" -ForegroundColor DarkGray
    } else {
        foreach ($a in @($cfg.accelerators)) {
            $estado = if ($a.enabled) { "habilitado" } else { "deshabilitado" }
            if ($a.PSObject.Properties['reason'] -and $a.reason) { $estado += " ($($a.reason))" }
            Write-KeyVal $a.key $estado
        }
    }

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
    'Set-DefaultMember',
    'Set-ComfyConfigProperty',
    'Reset-ComfyConfigProperty',
    'Show-ComfyConfig',
    'Format-ConfigValue',
    'Get-ComfyAccelerator',
    'Resolve-ComfyAcceleratorKey',
    'Get-SettingScope',
    'Show-SettingScope',
    'Test-ComfyAcceleratorEnabled'
)
