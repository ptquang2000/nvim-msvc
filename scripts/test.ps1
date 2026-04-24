# Run plenary-busted headless tests.
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) {
    Write-Error "nvim not found on PATH"
    exit 127
}

$cArg = "PlenaryBustedDirectory lua/msvc/test/ {minimal_init='tests/minimal_init.lua',sequential=true}"
Write-Host "Running: nvim --headless --noplugin -u tests/minimal_init.lua -c `"$cArg`""
& nvim --headless --noplugin -u tests/minimal_init.lua -c $cArg
exit $LASTEXITCODE
