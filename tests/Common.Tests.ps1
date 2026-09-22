BeforeAll {
    $script:SrcDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Import-Module (Join-Path $script:SrcDir 'Common.psm1') -Force
}

Describe 'Test-SafeChildPath' {
    BeforeAll { $script:Parent = 'D:\Apps\ComfyUI\ComfyUI\custom_nodes' }

    It 'acepta un nombre de carpeta simple' {
        Test-SafeChildPath -ParentDir $script:Parent -Name 'ComfyUI-Manager' | Should -BeTrue
    }

    # Regresion: una clase de regex mal escapada ('[\/]') solo bloqueaba '/',
    # dejando pasar el separador nativo de Windows.
    It 'rechaza travesia con barra invertida' {
        Test-SafeChildPath -ParentDir $script:Parent -Name '..\..\..\Windows' | Should -BeFalse
    }

    It 'rechaza travesia con barra normal' {
        Test-SafeChildPath -ParentDir $script:Parent -Name '../../etc' | Should -BeFalse
    }

    It 'rechaza referencias relativas' {
        Test-SafeChildPath -ParentDir $script:Parent -Name '..' | Should -BeFalse
        Test-SafeChildPath -ParentDir $script:Parent -Name '.'  | Should -BeFalse
    }

    It 'rechaza rutas absolutas con unidad' {
        Test-SafeChildPath -ParentDir $script:Parent -Name 'C:\Windows' | Should -BeFalse
    }

    It 'rechaza caracteres invalidos en nombre de archivo' {
        Test-SafeChildPath -ParentDir $script:Parent -Name 'a|b' | Should -BeFalse
    }
}

Describe 'Objetivos de PyTorch' {
    It 'solo admite versiones que uv.lock cubre' {
        $versions = Get-SupportedCudaVersions
        $versions | Should -Contain '12.6'
        $versions | Should -Contain '13.0'
        $versions.Count | Should -Be 2
    }

    It 'rechaza una version no soportada' {
        Test-CudaVersionSupported -Version '11.8' | Should -BeFalse
        Test-CudaVersionSupported -Version '12.4' | Should -BeFalse
    }

    # No debe caer a otro indice en silencio: devolver $null obliga a que el
    # llamante falle de forma visible.
    It 'devuelve null para una version no soportada, sin sustituirla' {
        Get-TorchIndexUrl -CudaVersion '11.8' | Should -BeNullOrEmpty
        Get-TorchExtra    -CudaVersion '11.8' | Should -BeNullOrEmpty
    }

    It 'mapea cada version a su indice y a su extra' {
        Get-TorchIndexUrl -CudaVersion '13.0' | Should -Be 'https://download.pytorch.org/whl/cu130'
        Get-TorchIndexUrl -CudaVersion '12.6' | Should -Be 'https://download.pytorch.org/whl/cu126'
        Get-TorchExtra    -CudaVersion '13.0' | Should -Be 'cu130'
        Get-TorchExtra    -CudaVersion '12.6' | Should -Be 'cu126'
    }

    It 'resuelve la ruta de CPU' {
        Get-TorchExtra    -CudaVersion $null -Cpu | Should -Be 'cpu'
        Get-TorchIndexUrl -CudaVersion $null -Cpu | Should -Be 'https://download.pytorch.org/whl/cpu'
    }
}

Describe 'Colores ANSI' {
    # Regresion: definirlos con $script: los confinaba al modulo, y todos los
    # Write-Host de los demas modulos imprimian cadena vacia.
    It 'expone las variables de color fuera del modulo' {
        $ColorGreen | Should -Not -BeNullOrEmpty
        $ColorReset | Should -Not -BeNullOrEmpty
    }
}
