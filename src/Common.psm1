# ==============================================================================
# Common.psm1 - Utilidades de consola, formato y localizacion de binarios
# ==============================================================================

Set-StrictMode -Version Latest

# Soporte de colores ANSI.
# Se exportan como variables del modulo (ver Export-ModuleMember -Variable al
# final) para que sean visibles desde los modulos que importan Common.psm1.
# Nota: usar $script: aqui las dejaria confinadas a este modulo.
$ESC = [char]27
$ColorReset   = "$ESC[0m"
$ColorBold    = "$ESC[1m"
$ColorCyan    = "$ESC[36m"
$ColorGreen   = "$ESC[32m"
$ColorYellow  = "$ESC[33m"
$ColorRed     = "$ESC[31m"
$ColorGray    = "$ESC[90m"

function Get-ProjectRoot {
    [CmdletBinding()]
    param()
    # Directorio raiz del repositorio (un nivel arriba de /src)
    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Write-StepHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Title)
    Write-Host "`n$ColorBold$ColorCyan==> $Title$ColorReset"
}

function Write-Info {
    [CmdletBinding()]
    param([string]$Message)
    Write-Host "$ColorCyan[INFO]$ColorReset $Message"
}

function Write-Success {
    [CmdletBinding()]
    param([string]$Message)
    Write-Host "$ColorGreen[ OK ]$ColorReset $Message"
}

function Write-WarningMsg {
    [CmdletBinding()]
    param([string]$Message)
    Write-Host "$ColorYellow[WARN]$ColorReset $Message"
}

function Write-ErrorMsg {
    [CmdletBinding()]
    param([string]$Message)
    Write-Host "$ColorRed[ERR ]$ColorReset $Message"
}

function Write-KeyVal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value
    )
    $paddedKey = $Key.PadRight(22)
    Write-Host "  $ColorBold$paddedKey$ColorReset : $ColorCyan$Value$ColorReset"
}

function Write-Banner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('Success','Warning','Error')][string]$Level = 'Success'
    )
    $color = switch ($Level) {
        'Success' { $ColorGreen }
        'Warning' { $ColorYellow }
        'Error'   { $ColorRed }
    }
    Write-Host "`n$ColorBold$color$Message$ColorReset`n"
}

function Find-UvExecutable {
    [CmdletBinding()]
    param()

    $cmd = Get-Command "uv" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidatePaths = @(
        "$env:LOCALAPPDATA\bin\uv.exe",
        "$env:USERPROFILE\.cargo\bin\uv.exe",
        "$env:USERPROFILE\.local\bin\uv.exe",
        "$env:PROGRAMFILES\uv\uv.exe"
    )
    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }

    $wingetPackages = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetPackages) {
        $uvMatch = Get-ChildItem -Path $wingetPackages -Filter "uv.exe" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($uvMatch) { return $uvMatch.FullName }
    }

    return $null
}

function Find-GitExecutable {
    [CmdletBinding()]
    param()

    $cmd = Get-Command "git" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidatePaths = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles\Git\bin\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )
    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }

    return $null
}

function Find-PythonInVenv {
    [CmdletBinding()]
    param([string]$VenvPath = "")

    if ([string]::IsNullOrWhiteSpace($VenvPath)) {
        $VenvPath = Join-Path (Get-ProjectRoot) ".venv"
    }
    $pyPath = Join-Path $VenvPath "Scripts\python.exe"
    if (Test-Path -LiteralPath $pyPath) { return $pyPath }
    return $null
}

function Invoke-UvPip {
    <#
    .SYNOPSIS
        Envoltorio de 'uv pip' que SIEMPRE fija el interprete de destino.
    .DESCRIPTION
        'uv pip install' sin --python resuelve el entorno a partir de
        $env:VIRTUAL_ENV o de un .venv en el directorio actual. Como este
        gestor se puede invocar desde cualquier cwd, omitir --python instala
        en un entorno impredecible. Este envoltorio lo hace explicito.
    .OUTPUTS
        [bool] $true si el comando termino con exito.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$UvExe,
        [Parameter(Mandatory=$true)][string]$PythonExe,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $PythonExe)) {
        Write-ErrorMsg "No existe el interprete de destino: $PythonExe"
        return $false
    }

    & $UvExe pip @Arguments --python $PythonExe
    return ($LASTEXITCODE -eq 0)
}

# Objetivos de PyTorch soportados. Solo se admiten los que pyproject.toml
# declara como extras y uv.lock fija: ofrecer una version que el lock no
# cubre daria una instalacion no reproducible. Debe mantenerse en sincronia
# con CUDA_WHEEL_INDEXES en src/probe_hardware.py y con los extras de
# pyproject.toml.
$script:CudaWheelIndexes = [ordered]@{
    "12.6" = "https://download.pytorch.org/whl/cu126"
    "13.0" = "https://download.pytorch.org/whl/cu130"
}
$script:CudaExtras = [ordered]@{
    "12.6" = "cu126"
    "13.0" = "cu130"
}
$script:CpuWheelIndex = "https://download.pytorch.org/whl/cpu"
$script:CpuExtra = "cpu"

function Get-TorchExtra {
    <#
    .SYNOPSIS
        Devuelve el extra de pyproject.toml para una version de CUDA.
    .DESCRIPTION
        Devuelve $null si la version no esta soportada, para que el llamante
        falle de forma visible en vez de instalar otra cosa.
    #>
    [CmdletBinding()]
    param(
        # No es obligatorio: la ruta de CPU invoca esta funcion con $null, que
        # PowerShell convierte a cadena vacia al enlazarlo a un [string].
        [AllowNull()][AllowEmptyString()][string]$CudaVersion = $null,
        [switch]$Cpu
    )
    if ($Cpu) { return $script:CpuExtra }
    if (-not (Test-CudaVersionSupported -Version $CudaVersion)) { return $null }
    return $script:CudaExtras[$CudaVersion]
}

function Get-SupportedCudaVersions {
    [CmdletBinding()]
    param()
    return @($script:CudaWheelIndexes.Keys)
}

function Test-CudaVersionSupported {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowNull()][string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    return $script:CudaWheelIndexes.Contains($Version)
}

function Get-TorchIndexUrl {
    <#
    .SYNOPSIS
        Devuelve el indice de ruedas para una version de CUDA, o el de CPU.
    .DESCRIPTION
        Devuelve $null si la version no esta soportada, en lugar de caer a un
        indice arbitrario: una version desconocida debe ser un error visible,
        no una instalacion silenciosa de otra cosa.
    #>
    [CmdletBinding()]
    param(
        # No es obligatorio: la ruta de CPU invoca esta funcion con $null, que
        # PowerShell convierte a cadena vacia al enlazarlo a un [string].
        [AllowNull()][AllowEmptyString()][string]$CudaVersion = $null,
        [switch]$Cpu
    )
    if ($Cpu) { return $script:CpuWheelIndex }
    if (-not (Test-CudaVersionSupported -Version $CudaVersion)) { return $null }
    return $script:CudaWheelIndexes[$CudaVersion]
}

function Test-SafeChildPath {
    <#
    .SYNOPSIS
        Verifica que $Name resuelva a un hijo directo de $ParentDir.
    .DESCRIPTION
        Defensa contra path traversal en operaciones destructivas: un nombre
        como '..\..\algo' escaparia del arbol de custom_nodes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ParentDir,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }

    # Rechazar separadores de ruta explicitamente. Se usa IndexOfAny con un
    # array de char en lugar de una clase de regex para no depender de como
    # se interprete el escape de la barra invertida.
    if ($Name.IndexOfAny([char[]]@('/', '\')) -ge 0) { return $false }

    # Rechazar '.', '..' y unidades tipo 'C:'.
    if ($Name -match '^\.+$' -or $Name -match '^[A-Za-z]:') { return $false }

    if ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        return $false
    }

    $resolvedParent = [System.IO.Path]::GetFullPath($ParentDir)
    $candidate      = [System.IO.Path]::GetFullPath((Join-Path $ParentDir $Name))
    $expected       = [System.IO.Path]::Combine($resolvedParent, $Name)

    return ($candidate -eq [System.IO.Path]::GetFullPath($expected))
}

Export-ModuleMember -Function @(
    'Get-ProjectRoot',
    'Write-StepHeader',
    'Write-Info',
    'Write-Success',
    'Write-WarningMsg',
    'Write-ErrorMsg',
    'Write-KeyVal',
    'Write-Banner',
    'Find-UvExecutable',
    'Find-GitExecutable',
    'Find-PythonInVenv',
    'Invoke-UvPip',
    'Get-SupportedCudaVersions',
    'Test-CudaVersionSupported',
    'Get-TorchIndexUrl',
    'Get-TorchExtra',
    'Test-SafeChildPath'
) -Variable @(
    'ColorReset','ColorBold','ColorCyan','ColorGreen',
    'ColorYellow','ColorRed','ColorGray'
)
