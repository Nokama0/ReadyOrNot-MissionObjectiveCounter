# tools/deploy.ps1
# Copies this repo's Scripts/*.lua into the game's UE4SS mods folder, for
# local testing. Purely additive: creates the MissionObjectiveCounter mod
# folder if it is not there yet, copies the .lua files into it, and
# touches nothing else. It never writes mods.txt; it only tells you the
# line to add if the mod is not already enabled there.
#
# Game root resolution order, first one that works wins:
#   1. -GameRoot parameter
#   2. RON_GAME_ROOT environment variable
#   3. Auto-detection through Steam: read Steam's install path from
#      HKCU:\Software\Valve\Steam (SteamPath), parse
#      steamapps\libraryfolders.vdf for every library Steam knows about,
#      and find the one whose "apps" block lists Ready or Not's Steam
#      app id (1144200). That identifies the right library even when the
#      game is not in Steam's default library.
#   4. None of the above resolved anything: fail loudly with an example
#      of how to supply one.
#
# Refuses to run while a ReadyOrNot process is alive, because writing
# into a watched Scripts directory of a live process has crashed the game
# during development (see UE4SS-NOTES.md, section 4, "The game thread
# requirement"). Pass -Force to override; UE4SS hot reload makes live
# deployment useful once you know the risk.
param(
    [string]$GameRoot,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Minimal VDF (Valve KeyValues) reader, just enough to walk
# libraryfolders.vdf: nested "key" { ... } blocks and "key" "value" pairs.
# ---------------------------------------------------------------------------
function Read-VdfObject {
    param($Lines, [ref]$Index)
    $obj = [ordered]@{}
    while ($Index.Value -lt $Lines.Count) {
        $line = $Lines[$Index.Value].Trim()
        $Index.Value++
        if ($line -eq '' -or $line -eq '{') { continue }
        if ($line -eq '}') { return $obj }
        if ($line -match '^"((?:[^"\\]|\\.)*)"\s*"((?:[^"\\]|\\.)*)"$') {
            $obj[$matches[1]] = $matches[2]
        } elseif ($line -match '^"((?:[^"\\]|\\.)*)"$') {
            $key = $matches[1]
            while ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Trim() -ne '{') {
                $Index.Value++
            }
            $Index.Value++ # consume the '{'
            $obj[$key] = Read-VdfObject -Lines $Lines -Index $Index
        }
    }
    return $obj
}

function Find-SteamGameRoot {
    param([string]$AppId, [string]$CommonFolderName)

    $prop = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction SilentlyContinue
    if (-not $prop) { return $null }

    $steamPath = $prop.SteamPath -replace '/', '\'
    $vdfPath = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdfPath)) { return $null }

    $lines = Get-Content -LiteralPath $vdfPath
    $idx = 0
    $parsed = Read-VdfObject -Lines $lines -Index ([ref]$idx)

    $libraries = $parsed['libraryfolders']
    if (-not $libraries) { return $null }

    foreach ($libKey in $libraries.Keys) {
        $lib = $libraries[$libKey]
        if ($lib -isnot [System.Collections.Specialized.OrderedDictionary]) { continue }
        $apps = $lib['apps']
        if ($apps -and $apps.Contains($AppId)) {
            $libPath = $lib['path'] -replace '\\\\', '\'
            $candidate = Join-Path $libPath "steamapps\common\$CommonFolderName"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 1. Resolve the game root
# ---------------------------------------------------------------------------
$resolvedFrom = $null
if ($GameRoot) {
    $resolvedFrom = '-GameRoot parameter'
} elseif ($env:RON_GAME_ROOT) {
    $GameRoot = $env:RON_GAME_ROOT
    $resolvedFrom = 'RON_GAME_ROOT environment variable'
} else {
    $GameRoot = Find-SteamGameRoot -AppId '1144200' -CommonFolderName 'Ready Or Not'
    if ($GameRoot) { $resolvedFrom = 'Steam auto-detection' }
}

if (-not $GameRoot) {
    throw @'
Could not resolve the Ready or Not game folder.

Tried, in order: -GameRoot, the RON_GAME_ROOT environment variable, and
auto-detection through Steam's registry key and libraryfolders.vdf. None
of them found it.

Pass the folder that contains the game's ReadyOrNot\ subfolder, for example:

    .\tools\deploy.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\Ready Or Not"

or set it once for the current shell:

    $env:RON_GAME_ROOT = "D:\SteamLibrary\steamapps\common\Ready Or Not"
    .\tools\deploy.ps1
'@
}

Write-Host "Game root ($resolvedFrom): $GameRoot" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 2. Verify before writing anything
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $GameRoot)) {
    throw "Resolved game root does not exist: $GameRoot"
}

$ue4ssMods = Join-Path $GameRoot 'ReadyOrNot\Binaries\Win64\ue4ss\Mods'
if (-not (Test-Path -LiteralPath $ue4ssMods)) {
    throw "UE4SS does not appear to be installed: $ue4ssMods was not found. Install UE4SS first (https://github.com/UE4SS-RE/RE-UE4SS/releases), then run this script again."
}

# ---------------------------------------------------------------------------
# 3. Refuse to deploy while the game is running, unless -Force
# ---------------------------------------------------------------------------
$running = Get-Process -Name 'ReadyOrNot*' -ErrorAction SilentlyContinue
if ($running -and -not $Force) {
    throw "Ready or Not appears to be running (process '$($running[0].ProcessName)'). Writing into a watched Scripts folder while the game is live has crashed it before. Close the game first, or pass -Force if you understand the risk (for example, to exercise UE4SS hot reload)."
}
if ($running -and $Force) {
    Write-Host "Ready or Not is running; continuing because -Force was passed." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 4. Copy the .lua files, purely additive
# ---------------------------------------------------------------------------
$sourceScriptsDir = Join-Path $root 'Scripts'
$sourceScripts = Get-ChildItem -LiteralPath $sourceScriptsDir -Filter '*.lua'
if (-not $sourceScripts) {
    throw "No .lua files found in $sourceScriptsDir"
}

$modDir = Join-Path $ue4ssMods 'MissionObjectiveCounter'
$destScriptsDir = Join-Path $modDir 'Scripts'
New-Item -ItemType Directory -Force -Path $destScriptsDir | Out-Null

foreach ($file in $sourceScripts) {
    $destPath = Join-Path $destScriptsDir $file.Name
    Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force

    $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $destHash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256).Hash
    if ($sourceHash -ne $destHash) {
        throw "Hash mismatch after copying $($file.Name): source $sourceHash, deployed $destHash. The copy is incomplete; do not trust this deployment."
    }
    Write-Host "Copied $($file.Name) (SHA256 verified: $sourceHash)" -ForegroundColor Green
}

Write-Host "Deployed to $destScriptsDir" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 5. Check mods.txt, but never write to it
# ---------------------------------------------------------------------------
$modsTxt = Join-Path $ue4ssMods 'mods.txt'
$enabled = $false
if (Test-Path -LiteralPath $modsTxt) {
    $enabled = [bool](Select-String -LiteralPath $modsTxt -Pattern '^\s*MissionObjectiveCounter\s*:\s*1\s*$' -Quiet)
}

if ($enabled) {
    Write-Host "mods.txt already enables MissionObjectiveCounter." -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'mods.txt does not enable MissionObjectiveCounter yet. Add this line:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '    MissionObjectiveCounter : 1' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "to $modsTxt, placed above the Keybinds line near the bottom of the file." -ForegroundColor Yellow
}
