[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^20\d{2}$')][string]$Year,
    [Parameter(Mandatory)][ValidatePattern('^[^\\/:*?"<>|]+$')][string]$Competition,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]\d*$')][string]$Question,
    [Parameter(Mandatory)][ValidatePattern('^[^\\/:*?"<>|]+$')][string]$Title
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$slug = "$Year-$Competition-$Question-$Title"
$problem = Join-Path $root (Join-Path 'problems' $slug)

if (Test-Path -LiteralPath $problem) {
    throw "题目工作区已存在，拒绝覆盖：$problem"
}

@(
    $problem,
    (Join-Path $problem "$Question 附件"),
    (Join-Path $problem 'model'),
    (Join-Path $problem 'code'),
    (Join-Path $problem 'output/figures'),
    (Join-Path $problem 'output/results'),
    (Join-Path $problem 'scratch')
) | ForEach-Object { New-Item -ItemType Directory -Path $_ | Out-Null }

$progress = @"
# 题目摘要与进度

## 题目元信息

| 项目 | 内容 |
|---|---|
| 竞赛 | $Competition |
| 题目 | $Question 题：$Title |
| 题目文件 | 待放入 |

## 题目要点

待补充题目背景、数据规模、关键条件和各小问。

## 文件夹结构与产出进度

| 目录 / 文件 | 状态 |
|---|---|
| `$Question 附件/` | 待导入（只读） |
| `model/` | 尚未开始 |
| `code/` | 尚未开始 |
| `output/figures/` | 尚未开始 |
| `output/results/` | 尚未开始 |
| `scratch/` | 过程性材料，不提交 |

## 更新日志

| 日期 | 变更 |
|---|---|
| $(Get-Date -Format 'yyyy-MM-dd') | 初始化工作区 |
"@
Set-Content -LiteralPath (Join-Path $problem '00_题目摘要与进度.md') -Value $progress -Encoding utf8

Write-Host "已创建：$problem"
