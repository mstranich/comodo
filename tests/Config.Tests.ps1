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

    It 'preinstala unicamente ComfyUI-Manager' {
        $nodes = @($script:Cfg.custom_nodes)
        $nodes.Count   | Should -Be 1
        $nodes[0].name | Should -Be 'ComfyUI-Manager'
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

        $norm.hardware      | Should -Not -BeNullOrEmpty
        $norm.runtime.port  | Should -Be 8188
        $norm.custom_nodes  | Should -Not -BeNullOrEmpty
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
