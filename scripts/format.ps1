# Format Lua sources with stylua.
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Get-Command stylua -ErrorAction SilentlyContinue)) {
    Write-Error "stylua not found on PATH"
    exit 127
}

Write-Host "Running: stylua lua tests"
& stylua lua tests
exit $LASTEXITCODE
