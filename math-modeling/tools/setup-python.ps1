[CmdletBinding()]
param([switch]$Recreate)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $root '.venv'

if (Test-Path -LiteralPath $venv) {
    if (-not $Recreate) {
        Write-Host "已存在虚拟环境：$venv"
        exit 0
    }
    Remove-Item -LiteralPath $venv -Recurse -Force
}

$python = $null
$pythonArgs = @()
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCommand) {
    $candidate = $pythonCommand.Source
    $candidateVersion = & $candidate -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    if ([version]$candidateVersion -eq [version]'3.12') {
        $python = $candidate
    }
}
if (-not $python) {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        $candidate = $launcher.Source
        $candidateVersion = & $candidate '-3.12' '-c' "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        if ([version]$candidateVersion -eq [version]'3.12') {
            $python = $candidate
            $pythonArgs = @('-3.12')
        }
    }
}
if (-not $python) {
    throw '未找到 Python 3.12。请安装 Python 3.12 并将 python 或 py 加入 PATH。'
}

& $python @pythonArgs '-m' 'venv' '--copies' $venv
$venvPython = Join-Path $venv 'Scripts\python.exe'
$lock = Join-Path $root 'requirements.lock'
& $venvPython '-m' 'pip' 'install' '--no-input' '-r' $lock
& $venvPython '-c' "import numpy,pandas,matplotlib,scipy,sklearn,ortools,openpyxl,pdfplumber; print('Python environment verified')"
