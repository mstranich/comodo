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

    It 'deja los aceleradores apagados hasta que probe decida' {
        $script:Cfg.optimizations.triton         | Should -BeFalse
        $script:Cfg.optimizations.sage_attention | Should -BeFalse
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
