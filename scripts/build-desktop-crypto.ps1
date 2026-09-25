# Builds the Rust crypto library for the Windows desktop app and puts it where
# the Flutter CMake build bundles it (Stage 3, decision D10).
#
#   scripts\build-desktop-crypto.ps1   -> mobile\windows\crypto\
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Crate = Join-Path $Root "crypto\rust"
$Destination = Join-Path $Root "mobile\windows\crypto"
$Metadata = Join-Path $Destination "metadata"

Push-Location $Crate
try {
  cargo build --locked --release
  if ($LASTEXITCODE -ne 0) { throw "crypto library build failed" }
} finally {
  Pop-Location
}

New-Item -ItemType Directory -Force -Path $Metadata | Out-Null
Copy-Item (Join-Path $Crate "target\release\private_messenger_crypto.dll") $Destination -Force

$Revision = git -C $Root rev-parse HEAD
$LockHash = (Get-FileHash -Algorithm SHA256 (Join-Path $Crate "Cargo.lock")).Hash.ToLower()
$Rustc = rustc -Vv
@("source_revision=$Revision", "cargo_lock_sha256=$LockHash") + $Rustc |
  Set-Content -Path (Join-Path $Metadata "build-info.txt")
Push-Location $Crate
try {
  # cmd pipes bytes unchanged. Windows PowerShell 5.1 re-encodes text piped
  # between programs and adds a byte-order mark that Python's JSON rejects.
  $LicenseScript = Join-Path $Root "scripts\cargo-license-metadata.py"
  $LicenseOutput = Join-Path $Metadata "cargo-metadata.json"
  cmd /c "cargo metadata --locked --format-version 1 | python `"$LicenseScript`" > `"$LicenseOutput`""
  if ($LASTEXITCODE -ne 0) { throw "license metadata failed" }
} finally {
  Pop-Location
}
Copy-Item (Join-Path $Crate "include\veritra_crypto.h") $Metadata -Force
Write-Host "Windows crypto library ready in $Destination"
