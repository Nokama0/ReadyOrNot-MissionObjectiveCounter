# tools/run-tests.ps1
# Runs the headless layout tests. Must be run from the repo root.
#
# The interpreter must match UE4SS's embedded Lua. UE4SS 3.0.1's binary
# (UE4SS.dll) carries the string "$LuaVersion: Lua 5.4.7 Copyright (C)
# 1994-2024 Lua.org, PUC-Rio" and contains zero LuaJIT strings: the runtime
# is Lua 5.4.7, not LuaJIT. Running the suite under a 5.1-dialect
# interpreter, or under LuaJIT, can pass code that then raises in game,
# which defeats the point of having a test suite at all, so this resolves
# to a real Lua 5.4 interpreter.
#
# Resolution order: $env:LUA (a path to the interpreter, for a machine where
# neither name below is on PATH), then `lua` on PATH, then `lua54` on PATH.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $lua = if ($env:LUA) {
        $env:LUA
    } elseif (Get-Command lua -ErrorAction SilentlyContinue) {
        'lua'
    } else {
        'lua54'
    }

    & $lua tests/layout_spec.lua
    if ($LASTEXITCODE -ne 0) { throw "layout tests failed" }
    Write-Host "layout tests passed" -ForegroundColor Green
} finally {
    Pop-Location
}
