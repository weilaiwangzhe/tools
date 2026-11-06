$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$schemaDir = Join-Path $root 'protocol/schemas'
$required = @('pairing-profile.schema.json', 'control-message.schema.json', 'file-transfer.schema.json')
foreach ($name in $required) {
    $path = Join-Path $schemaDir $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing schema: $path" }
    $null = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "OK $name"
}
Write-Host 'Protocol schema validation passed.'
