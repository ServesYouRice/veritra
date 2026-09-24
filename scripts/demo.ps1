# One-command local demo server (Stage 1.8, decisions D10-D12).
#
#   scripts\demo.ps1            build and start the server on 127.0.0.1:8080
#   scripts\demo.ps1 -Reset     wipe the demo data first
#   scripts\demo.ps1 -Port N    use another port
#
# The server listens on loopback only. Demo apps reach it over plain HTTP,
# which they accept for loopback hosts only (D12). The Android emulator
# reaches it through `adb reverse`, which this script sets up when adb is
# available. Data lives in data\demo (git-ignored).
param(
  [switch]$Reset,
  [int]$Port = 8080
)
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$DemoDir = Join-Path $Root "data\demo"
$ServerExe = Join-Path $DemoDir "veritra-server.exe"

if ($Reset -and (Test-Path $DemoDir)) {
  Write-Host "Removing demo data in $DemoDir"
  Remove-Item -Recurse -Force $DemoDir
}
New-Item -ItemType Directory -Force -Path (Join-Path $DemoDir "server") | Out-Null

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
  throw "Go is required: install the version in .go-version from https://go.dev/dl/"
}

Write-Host "Building the server..."
Push-Location (Join-Path $Root "server")
try {
  go build -trimpath -o $ServerExe ./cmd/messenger-server
  if ($LASTEXITCODE -ne 0) { throw "server build failed" }
} finally {
  Pop-Location
}

if (Get-Command cargo -ErrorAction SilentlyContinue) {
  Write-Host "Building the crypto library for desktop apps..."
  Push-Location (Join-Path $Root "crypto\rust")
  try {
    cargo build --locked --release --quiet
    if ($LASTEXITCODE -ne 0) { throw "crypto library build failed" }
  } finally {
    Pop-Location
  }
} else {
  Write-Host "Skipping the crypto library: cargo not found (only needed for desktop apps)."
}

# The setup token only matters until the owner account exists. Keep it with
# the demo data so a restart before setup shows the same one.
$TokenFile = Join-Path $DemoDir "setup-token"
if (-not (Test-Path $TokenFile) -or (Get-Item $TokenFile).Length -eq 0) {
  & $ServerExe generate-setup-token | Set-Content -NoNewline -Path $TokenFile
}
$SetupToken = (Get-Content -Raw $TokenFile).Trim()

$AndroidNote = "start an emulator, then run: adb reverse tcp:$Port tcp:$Port"
if (Get-Command adb -ErrorAction SilentlyContinue) {
  adb get-state *> $null
  if ($LASTEXITCODE -eq 0) {
    adb reverse "tcp:$Port" "tcp:$Port" *> $null
    if ($LASTEXITCODE -eq 0) {
      $AndroidNote = "adb reverse is set up for the running emulator"
    }
  }
}

Write-Host @"

Veritra demo server
  Server URL (every app):  http://localhost:$Port
  Setup token (first run): $SetupToken
  Android emulator:        $AndroidNote
  Data:                    $DemoDir

Start an app (from mobile\):
  flutter run -t lib/main_demo.dart --dart-define=VERITRA_DEMO=true
See docs\demo.md for the full walkthrough. Press Ctrl+C to stop.

"@

$env:PRIVATE_MESSENGER_ENV = "development"
$env:PRIVATE_MESSENGER_SETUP_TOKEN = $SetupToken
$env:PRIVATE_MESSENGER_INSTANCE_NAME = "Veritra demo"
& $ServerExe serve --addr "127.0.0.1:$Port" --data-dir (Join-Path $DemoDir "server")
exit $LASTEXITCODE
