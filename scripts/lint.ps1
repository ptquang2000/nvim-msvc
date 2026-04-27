# Lint Lua sources with luacheck.
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Get-Command luacheck -ErrorAction SilentlyContinue)) {
    Write-Error "luacheck not found on PATH"
    exit 127
}

Write-Host "Running: luacheck lua tests"
& luacheck lua tests
exit $LASTEXITCODE
