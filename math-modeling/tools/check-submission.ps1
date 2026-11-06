[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Pdf,
    [string]$SupportArchive,
    [string[]]$ForbiddenTerms = @()
)

$ErrorActionPreference = 'Stop'
$pdfFile = Get-Item -LiteralPath $Pdf
if ($pdfFile.Extension -ne '.pdf') { throw 'Pdf 参数必须指向 .pdf 文件。' }
if ($pdfFile.Length -gt 20MB) { throw "论文 PDF 为 $([math]::Round($pdfFile.Length / 1MB, 2)) MiB，超过规则限定的 20 MB。" }

$targets = @($pdfFile)
if ($SupportArchive) { $targets += Get-Item -LiteralPath $SupportArchive }

foreach ($term in $ForbiddenTerms) {
    if ([string]::IsNullOrWhiteSpace($term)) { continue }
    foreach ($target in $targets) {
        if ($target.Name -match [regex]::Escape($term)) {
            throw "提交文件名含禁用身份词：'$term' → $($target.Name)"
        }
    }
}

Write-Host "通过：PDF 大小 $([math]::Round($pdfFile.Length / 1MB, 2)) MiB（≤ 20 MiB）。"
if ($ForbiddenTerms.Count -eq 0) {
    Write-Warning '尚未提供 -ForbiddenTerms；请至少传入队员姓名、学校和赛区后再提交。'
} else {
    Write-Host '通过：目标提交文件名未发现指定身份词。'
}
Write-Warning '此脚本不能可靠提取扫描型 PDF 的正文；提交前仍应人工检查 PDF、TeX 源码和压缩包内容。'
