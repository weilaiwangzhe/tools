param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '项目网络图-修复版.exe')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $PSScriptRoot 'ProjectGraphLauncher.cs'
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) { throw '找不到 Windows C# 编译器。' }

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path $outputFullPath -Parent
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /utf8output /out:$outputFullPath $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputFullPath)) {
    throw '项目网络图 EXE 编译失败。'
}
Write-Output "已生成：$outputFullPath"
