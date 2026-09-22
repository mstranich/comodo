# ==============================================================================
# Installer.psm1 - Descarga y aprovisionamiento de ComfyUI
# ==============================================================================

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Config.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Checker.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "Probe.psm1") -DisableNameChecking

function Install-CustomNodeRepo {
    <#
    .SYNOPSIS
        Clona (o reutiliza) un repositorio de nodo e instala sus dependencias.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Node,
        [Parameter(Mandatory=$true)][string]$CustomNodesDir,
        [Parameter(Mandatory=$true)][string]$GitExe,
        [Parameter(Mandatory=$true)][string]$UvExe,
        [Parameter(Mandatory=$true)][string]$PythonExe
    )

    if (-not (Test-SafeChildPath -ParentDir $CustomNodesDir -Name $Node.name)) {
        Write-ErrorMsg "Nombre de nodo invalido, se omite: '$($Node.name)'"
        return $false
    }

    $targetDir = Join-Path $CustomNodesDir $Node.name

    if (Test-Path -LiteralPath $targetDir) {
        Write-Success "Nodo ya presente: $($Node.name)"
    } else {
        Write-Info "Clonando $($Node.name) desde $($Node.url)..."
        & $GitExe clone --depth 1 $Node.url $targetDir
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "No se pudo clonar $($Node.name) desde $($Node.url)."
            return $false
        }
        Write-Success "Nodo $($Node.name) clonado."
    }

    $nodeReqs = Join-Path $targetDir "requirements.txt"
    if (Test-Path -LiteralPath $nodeReqs) {
        Write-Info "Instalando dependencias de $($Node.name)..."
        if (-not (Invoke-UvPip -UvExe $UvExe -PythonExe $PythonExe -Arguments @('install','-r',$nodeReqs))) {
            Write-WarningMsg "Fallaron dependencias de $($Node.name). El nodo puede no cargar."
            return $false
        }
    }

    return $true
}

function Invoke-ComfySetup {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [AllowNull()][string]$CudaVersion = $null,
        [switch]$SkipOptimizations,
        [switch]$SkipNodes,
        [switch]$AllowCpu
    )

    $rootDir = Get-ProjectRoot
    Write-StepHeader "Aprovisionamiento de ComfyUI (setup)"

    # --- 1. Herramientas del sistema -----------------------------------------
    $uvExe  = Find-UvExecutable
    $gitExe = Find-GitExecutable

    if (-not $uvExe -or -not $gitExe) {
        Write-WarningMsg "Faltan herramientas esenciales. Verificando requisitos previos..."
        Invoke-PreRequisites | Out-Null
        $uvExe  = Find-UvExecutable
        $gitExe = Find-GitExecutable
        if (-not $uvExe -or -not $gitExe) {
            Write-ErrorMsg "No se puede continuar sin 'uv' y 'git'."
            return $false
        }
    }

    # --- 2. Configuracion (probe automatico si hace falta) --------------------
    $cfgPath = Join-Path $rootDir "etc\config.json"
    $config  = Get-ComfyConfig

    if (-not (Test-Path -LiteralPath $cfgPath) -or -not $config.hardware.vendor) {
        Write-Info "Sin hardware detectado todavia. Ejecutando deteccion automatica..."
        if ($null -eq (Invoke-HardwareProbe)) {
            Write-ErrorMsg "La deteccion de hardware fallo. Ejecuta 'probe' manualmente."
            return $false
        }
        $config = Get-ComfyConfig
    }

    # --- 3. Resolver objetivo de PyTorch -------------------------------------
    if ($CudaVersion) {
        if (-not (Test-CudaVersionSupported -Version $CudaVersion)) {
            Write-ErrorMsg "Version de CUDA no soportada: '$CudaVersion'."
            Write-Info "Valores validos: $((Get-SupportedCudaVersions) -join ', ')"
            return $false
        }
        $config.install.cuda_version    = $CudaVersion
        $config.install.torch_index_url = Get-TorchIndexUrl -CudaVersion $CudaVersion
        Save-ComfyConfig -Config $config
        Write-Info "CUDA forzada por linea de comandos: $CudaVersion"
    }

    $isCuda = ($config.hardware.accelerator -eq 'cuda')

    if (-not $isCuda) {
        Write-WarningMsg "No se detecto una GPU NVIDIA utilizable."
        Write-WarningMsg "La instalacion usaria PyTorch CPU, que para difusion es extremadamente lento."
        if (-not $AllowCpu) {
            Write-ErrorMsg "Abortado. Si realmente quieres instalar en modo CPU, repite con: setup --allow-cpu"
            return $false
        }
        Write-Info "Continuando en modo CPU por peticion explicita (--allow-cpu)."
        $torchIndex = Get-TorchIndexUrl -CudaVersion $null -Cpu
    }
    else {
        $torchIndex = $config.install.torch_index_url
        if (-not $torchIndex) {
            $torchIndex = Get-TorchIndexUrl -CudaVersion $config.install.cuda_version
        }
        if (-not $torchIndex) {
            Write-ErrorMsg "No hay un indice de PyTorch valido para CUDA '$($config.install.cuda_version)'."
            Write-Info "Ejecuta 'probe' de nuevo o fija uno con: setup --cuda <version>"
            return $false
        }
    }

    # --- 4. Clonar ComfyUI ---------------------------------------------------
    $comfyDir = Join-Path $rootDir $config.install.install_dir
    Write-StepHeader "Paso 1/5: Repositorio de ComfyUI"
    if (Test-Path -LiteralPath $comfyDir) {
        Write-Success "ComfyUI ya presente en: $comfyDir"
    } else {
        Write-Info "Clonando ComfyUI..."
        & $gitExe clone $config.install.comfy_repo $comfyDir
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "Fallo al clonar ComfyUI desde $($config.install.comfy_repo)"
            return $false
        }
        Write-Success "ComfyUI clonado."
    }

    # --- 5. Entorno virtual --------------------------------------------------
    Write-StepHeader "Paso 2/5: Entorno virtual (.venv)"
    $venvDir = Join-Path $rootDir ".venv"
    $pyVer   = $config.install.python_version

    if ($Force -and (Test-Path -LiteralPath $venvDir)) {
        Write-Info "--force: eliminando el entorno virtual existente..."
        Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $venvDir)) {
        Write-Info "Creando entorno virtual con Python $pyVer..."
        & $uvExe venv $venvDir --python $pyVer
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "Fallo al crear el entorno virtual con uv."
            return $false
        }
        Write-Success "Entorno virtual creado: $venvDir"
    } else {
        Write-Success "Entorno virtual existente: $venvDir"
    }

    $pyExe = Join-Path $venvDir "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $pyExe)) {
        Write-ErrorMsg "No se encontro el interprete del venv en: $pyExe"
        return $false
    }

    # --- 6. PyTorch ----------------------------------------------------------
    $targetLabel = if ($isCuda) { "CUDA $($config.install.cuda_version)" } else { "CPU" }
    Write-StepHeader "Paso 3/5: PyTorch ($targetLabel)"
    Write-Info "Instalando torch, torchvision y torchaudio desde $torchIndex..."
    $torchOk = Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments @(
        'install','torch','torchvision','torchaudio','--index-url',$torchIndex
    )
    if (-not $torchOk) {
        Write-ErrorMsg "Fallo la instalacion de PyTorch."
        return $false
    }
    Write-Success "PyTorch instalado."

    # --- 7. Dependencias del nucleo ------------------------------------------
    Write-StepHeader "Paso 4/5: Dependencias de ComfyUI"
    $reqFile = Join-Path $comfyDir "requirements.txt"
    if (Test-Path -LiteralPath $reqFile) {
        if (Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments @('install','-r',$reqFile)) {
            Write-Success "Dependencias de ComfyUI instaladas."
        } else {
            Write-ErrorMsg "Fallaron las dependencias de ComfyUI."
            return $false
        }
    } else {
        Write-WarningMsg "No se encontro requirements.txt en $comfyDir"
    }

    # --- 8. Aceleradores segun hardware --------------------------------------
    # Cada acelerador se instala solo si el hardware lo soporta, segun lo que
    # decidio 'probe'. Los flags de optimizations/ son independientes entre si.
    if ($SkipOptimizations) {
        Write-Info "Aceleradores omitidos por --skip-opt."
    }
    elseif (-not $isCuda) {
        Write-Info "Sin CUDA: no se instalan aceleradores."
    }
    else {
        Write-StepHeader "Paso 5/5: Aceleradores"
        $wantTriton = [bool]$config.optimizations.triton
        $wantSage   = [bool]$config.optimizations.sage_attention

        if (-not $wantTriton -and -not $wantSage) {
            Write-Info "Tu GPU no reune los requisitos para Triton ni SageAttention. Se omiten."
        }

        if ($wantTriton) {
            Write-Info "Instalando triton-windows..."
            if (-not (Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments @('install','triton-windows'))) {
                Write-WarningMsg "Fallo triton-windows. ComfyUI funcionara sin el."
                $config.optimizations.triton = $false
            }
        }

        if ($wantSage) {
            Write-Info "Instalando sageattention..."
            if (-not (Invoke-UvPip -UvExe $uvExe -PythonExe $pyExe -Arguments @('install','sageattention'))) {
                Write-WarningMsg "Fallo sageattention. Se desactiva --use-sage-attention."
                $config.optimizations.sage_attention = $false
                $config.runtime.sage_attention = $false
            }
        }

        Save-ComfyConfig -Config $config
        Write-Info "Verificando la instalacion..."
        & $pyExe -c @'
import torch
print("[torch] " + torch.__version__ + " | CUDA disponible: " + str(torch.cuda.is_available()))
if torch.cuda.is_available():
    print("[torch] GPU: " + torch.cuda.get_device_name(0))
for mod in ("triton", "sageattention"):
    try:
        __import__(mod)
        print("[" + mod + "] OK")
    except Exception as exc:
        print("[" + mod + "] no disponible: " + str(exc))
'@
    }

    # --- 9. Nodos personalizados ---------------------------------------------
    if ($SkipNodes) {
        Write-Info "Nodos omitidos por --skip-nodes."
    } else {
        Write-StepHeader "Nodos personalizados"
        $customNodesDir = Join-Path $comfyDir "custom_nodes"
        if (-not (Test-Path -LiteralPath $customNodesDir)) {
            New-Item -ItemType Directory -Path $customNodesDir -Force | Out-Null
        }

        $nodes = @($config.custom_nodes | Where-Object { $_ -and $_.enabled })
        if ($nodes.Count -eq 0) {
            Write-Info "No hay nodos habilitados en etc/config.json."
        } else {
            foreach ($node in $nodes) {
                Install-CustomNodeRepo -Node $node -CustomNodesDir $customNodesDir `
                    -GitExe $gitExe -UvExe $uvExe -PythonExe $pyExe | Out-Null
            }
        }
    }

    Write-Banner "[OK] ComfyUI aprovisionado." -Level Success
    Write-KeyVal "GPU"    (Format-ConfigValue $config.hardware.model)
    Write-KeyVal "Perfil" (Format-ConfigValue $config.hardware.profile)
    Write-Info "Inicia el servidor con:"
    Write-Host "  .\comodo.ps1 start`n" -ForegroundColor Yellow

    return $true
}

Export-ModuleMember -Function 'Invoke-ComfySetup'
