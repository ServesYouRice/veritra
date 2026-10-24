# Live test of the demo message flow on Windows (work package W1): real
# OpenMLS clients (the Windows crypto DLL) against a local server on loopback
# that the test starts, stops and restarts. Mirrors scripts/test-demo-e2e.sh.
#
#   scripts\test-demo-e2e.ps1
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("veritra-e2e-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

try {
  $ServerExe = Join-Path $TempRoot "veritra-server.exe"
  Push-Location (Join-Path $Root "server")
  try {
    go build -trimpath -o $ServerExe ./cmd/messenger-server
    if ($LASTEXITCODE -ne 0) { throw "server build failed" }
  } finally {
    Pop-Location
  }

  Push-Location (Join-Path $Root "crypto\rust")
  try {
    cargo build --locked --release
    if ($LASTEXITCODE -ne 0) { throw "crypto library build failed" }
  } finally {
    Pop-Location
  }

  $Port = if ($env:VERITRA_DEMO_E2E_PORT) { $env:VERITRA_DEMO_E2E_PORT } else { "18082" }
  $env:VERITRA_DEMO_E2E_SERVER = $ServerExe
  $env:VERITRA_DEMO_E2E_DATA = Join-Path $TempRoot "data"
  $env:VERITRA_DEMO_E2E_PORT = $Port
  $env:VERITRA_CRYPTO_LIBRARY = Join-Path $Root "crypto\rust\target\release\private_messenger_crypto.dll"
  if (-not (Test-Path $env:VERITRA_CRYPTO_LIBRARY)) { throw "crypto DLL not found" }

  # flutter test resolves the project from the current directory.
  Push-Location (Join-Path $Root "mobile")
  try {
    flutter test test/demo_e2e_test.dart
    if ($LASTEXITCODE -ne 0) { throw "demo e2e test failed" }
  } finally {
    Pop-Location
  }
} finally {
  Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
}
