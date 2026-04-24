# Run format-check + lint + test. Exits non-zero on any failure.
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Get-Command stylua -ErrorAction SilentlyContinue)) {
    Write-Error "stylua not found on PATH"
    exit 127
}

Write-Host "Running: stylua --check lua tests"
& stylua --check lua tests
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Running: $PSScriptRoot\lint.ps1"
& "$PSScriptRoot\lint.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Running: $PSScriptRoot\test.ps1"
& "$PSScriptRoot\test.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

exit 0
