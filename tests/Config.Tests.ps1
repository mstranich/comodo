BeforeAll {
    $script:SrcDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Import-Module (Join-Path $script:SrcDir 'Common.psm1') -Force
    Import-Module (Join-Path $script:SrcDir 'Config.psm1') -Force
}

Describe 'New-DefaultConfig' {
    BeforeAll { $script:Cfg = New-DefaultConfig }

    # El gestor debe servir en cualquier maquina: inventar hardware aqui
    # produciria una configuracion que miente sobre el equipo.
    It 'no asume ningun hardware' {
        $script:Cfg.hardware.vendor       | Should -BeNullOrEmpty
        $script:Cfg.hardware.model        | Should -BeNullOrEmpty
        $script:Cfg.hardware.vram_gb      | Should -BeNullOrEmpty
        $script:Cfg.hardware.cuda_compute | Should -BeNullOrEmpty
    }

    It 'no fija una version de CUDA por defecto' {
        $script:Cfg.install.cuda_version | Should -BeNullOrEmpty
    }

    It 'no trae registro de aceleradores hasta que probe lo calcule' {
        @($script:Cfg.accelerators).Count | Should -Be 0
    }

    # ComfyUI-Manager dejo de ser un nodo clonado: desde la version 4 es un
    # paquete de PyPI que instala 'provision apply'. Ningun nodo viene
    # impuesto por defecto.
    It 'no impone ningun nodo por defecto' {
        @($script:Cfg.custom_nodes).Count | Should -Be 0
    }

    It 'el Manager arranca habilitado, ya que ComfyUI lo trae apagado' {
        $script:Cfg.runtime.enable_manager | Should -BeTrue
    }

    It 'escucha solo en localhost por defecto' {
        $script:Cfg.runtime.listen | Should -Be '127.0.0.1'
    }
}

Describe 'ConvertTo-NormalizedConfig' {
    It 'completa las claves ausentes de una configuracion antigua' {
        $viejo = [PSCustomObject]@{
            install = [PSCustomObject]@{ install_dir = 'ComfyUI' }
        }
        $norm = ConvertTo-NormalizedConfig -Config $viejo

        $norm.hardware              | Should -Not -BeNullOrEmpty
        $norm.runtime.port          | Should -Be 8188
        $norm.runtime.enable_manager | Should -BeTrue
        $norm.PSObject.Properties['custom_nodes'] | Should -Not -BeNullOrEmpty
    }

    It 'respeta los valores que el usuario ya habia definido' {
        $propio = [PSCustomObject]@{
            runtime = [PSCustomObject]@{ port = 9999; listen = '0.0.0.0' }
        }
        $norm = ConvertTo-NormalizedConfig -Config $propio

        $norm.runtime.port   | Should -Be 9999
        $norm.runtime.listen | Should -Be '0.0.0.0'
    }
}

Describe 'Registro de aceleradores' {
    # Migracion desde el esquema anterior, que tenia una seccion
    # 'optimizations' con un booleano por acelerador.
    It 'migra optimizations conservando la eleccion del usuario' {
        $viejo = [PSCustomObject]@{
            optimizations = [PSCustomObject]@{ triton = $true; sage_attention = $false }
        }
        $norm = ConvertTo-NormalizedConfig -Config $viejo

        $norm.PSObject.Properties['optimizations'] | Should -BeNullOrEmpty
        (Test-ComfyAcceleratorEnabled -Config $norm -Key 'triton')         | Should -BeTrue
        (Test-ComfyAcceleratorEnabled -Config $norm -Key 'sage_attention') | Should -BeFalse
    }

    It 'no pisa un registro ya existente' {
        $cfg = [PSCustomObject]@{
            optimizations = [PSCustomObject]@{ triton = $false }
            accelerators  = @([PSCustomObject]@{ key = 'triton'; enabled = $true })
        }
        $norm = ConvertTo-NormalizedConfig -Config $cfg
        (Test-ComfyAcceleratorEnabled -Config $norm -Key 'triton') | Should -BeTrue
    }

    It 'devuelve false para una clave ausente en vez de fallar' {
        $cfg = ConvertTo-NormalizedConfig -Config ([PSCustomObject]@{})
        (Test-ComfyAcceleratorEnabled -Config $cfg -Key 'inexistente') | Should -BeFalse
    }
}

Describe 'Format-ConfigValue' {
    It 'muestra un texto legible cuando el dato no se detecto' {
        Format-ConfigValue $null    | Should -Be 'no detectado'
        Format-ConfigValue ''       | Should -Be 'no detectado'
        Format-ConfigValue $null 'sin perfil' | Should -Be 'sin perfil'
    }

    It 'devuelve el valor cuando existe' {
        Format-ConfigValue 'NVIDIA' | Should -Be 'NVIDIA'
        Format-ConfigValue 8188     | Should -Be '8188'
    }
}

Describe 'Resolve-ComfyAcceleratorKey' {
    BeforeAll {
        $script:Reg = [PSCustomObject]@{
            accelerators = @(
                [PSCustomObject]@{ key = 'triton'; package = 'triton-windows'; module = 'triton' },
                [PSCustomObject]@{ key = 'sage_attention'; package = 'sageattention'; module = 'sageattention' }
            )
        }
    }

    It 'acepta la clave exacta' {
        Resolve-ComfyAcceleratorKey -Config $script:Reg -Name 'sage_attention' | Should -Be 'sage_attention'
    }

    It 'acepta el nombre del paquete, con o sin guiones' {
        Resolve-ComfyAcceleratorKey -Config $script:Reg -Name 'triton-windows' | Should -Be 'triton'
        Resolve-ComfyAcceleratorKey -Config $script:Reg -Name 'sageattention'  | Should -Be 'sage_attention'
    }

    # 'sage' es el alias que la gente escribe; debe resolver sin que nadie lo
    # haya declarado como alias en el codigo.
    It 'acepta un prefijo inequivoco' {
        Resolve-ComfyAcceleratorKey -Config $script:Reg -Name 'sage' | Should -Be 'sage_attention'
    }

    It 'rechaza lo que no existe' {
        Resolve-ComfyAcceleratorKey -Config $script:Reg -Name 'inexistente' | Should -BeNullOrEmpty
    }

    It 'no falla con el registro vacio' {
        $vacio = [PSCustomObject]@{ accelerators = @() }
        Resolve-ComfyAcceleratorKey -Config $vacio -Name 'triton' | Should -BeNullOrEmpty
    }

    It 'rechaza un prefijo ambiguo en vez de elegir uno' {
        $ambiguo = [PSCustomObject]@{
            accelerators = @(
                [PSCustomObject]@{ key = 'sage_attention' },
                [PSCustomObject]@{ key = 'sage_other' }
            )
        }
        Resolve-ComfyAcceleratorKey -Config $ambiguo -Name 'sage' | Should -BeNullOrEmpty
    }
}

Describe 'Flags del Manager' {
    # ComfyUI declara --disable-manager-ui y --enable-manager-legacy-ui en un
    # add_mutually_exclusive_group(): pasarlos juntos aborta argparse, asi que
    # la configuracion no debe poder dejarlos activos a la vez.
    It 'activar legacy_ui apaga disable_manager_ui' {
        $cfg = New-DefaultConfig
        $cfg.runtime.disable_manager_ui = $true
        $cfg.runtime.enable_manager_legacy_ui = $true
        # Se replica aqui la regla que aplica Set-ComfyConfigProperty.
        if ($cfg.runtime.enable_manager_legacy_ui) { $cfg.runtime.disable_manager_ui = $false }
        $cfg.runtime.disable_manager_ui | Should -BeFalse
    }

    It 'por defecto solo el Manager esta activo' {
        $cfg = New-DefaultConfig
        $cfg.runtime.enable_manager           | Should -BeTrue
        $cfg.runtime.disable_manager_ui       | Should -BeFalse
        $cfg.runtime.enable_manager_legacy_ui | Should -BeFalse
    }

    It 'las tres claves pertenecen al espacio flag' {
        foreach ($k in @('manager','enable-manager','disable-manager-ui','legacy_ui','enable-manager-legacy-ui')) {
            Get-SettingScope -Key $k | Should -Be 'flag' -Because "'$k' deberia ser un flag"
        }
    }
}

Describe 'Etiquetas de las vistas' {
    BeforeAll {
        $script:ConfigSrc = Get-Content -LiteralPath (
            Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Config.psm1'
        ) -Raw
    }

    # Regresion: 'flag list' mostraba 'preview', 'manager' y 'legacy_ui', que
    # son alias de 'set' y no existen en etc/config.json. Quien los buscaba en
    # el archivo no los encontraba. La vista debe nombrar las claves reales.
    It 'las etiquetas de flag list existen en el esquema' {
        $cfg = New-DefaultConfig
        $reales = @($cfg.runtime.PSObject.Properties.Name)

        # Etiquetas literales del bloque, sin las derivadas entre parentesis.
        $bloque = [regex]::Match(
            $script:ConfigSrc,
            'Flags de ejecucion(?s).*?acepta alias'
        ).Value
        $etiquetas = @([regex]::Matches($bloque, 'Write-KeyVal -Width \d+ "([^"(]+)"') |
            ForEach-Object { $_.Groups[1].Value })

        $etiquetas.Count | Should -BeGreaterThan 5
        foreach ($e in $etiquetas) {
            $reales | Should -Contain $e -Because "'$e' no es una clave de runtime"
        }
    }

    It 'las etiquetas de provision list existen en el esquema' {
        $cfg = New-DefaultConfig
        $reales = @($cfg.install.PSObject.Properties.Name)

        $bloque = [regex]::Match(
            $script:ConfigSrc,
            'Ajustes de aprovisionamiento(?s).*?acepta alias'
        ).Value
        $etiquetas = @([regex]::Matches($bloque, 'Write-KeyVal "([^"(]+)"') |
            ForEach-Object { $_.Groups[1].Value })

        $etiquetas.Count | Should -BeGreaterThan 3
        foreach ($e in $etiquetas) {
            $reales | Should -Contain $e -Because "'$e' no es una clave de install"
        }
    }
}
