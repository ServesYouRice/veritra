# Builds the Rust crypto library for the Windows desktop app and puts it where
# the Flutter CMake build bundles it (Stage 3, decision D10).
#
#   scripts\build-desktop-crypto.ps1   -> mobile\windows\crypto\
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Crate = Join-Path $Root "crypto\rust"
$Destination = Join-Path $Root "mobile\windows\crypto"
$Metadata = Join-Path $Destination "metadata"

# Read what is about to be built before cargo runs. $ErrorActionPreference
# does not cover native exit codes, so each git and rustc call is checked, and
# a malformed value stops the build instead of being written as provenance.
$Revision = "$(git -C $Root rev-parse --verify HEAD)"
if ($LASTEXITCODE -ne 0) { throw "crypto provenance: cannot read the source revision" }
if ($Revision -cnotmatch '^[0-9a-f]{40}$') { throw "crypto provenance: malformed source revision: $Revision" }
$LockHash = "$((Get-FileHash -Algorithm SHA256 (Join-Path $Crate "Cargo.lock")).Hash)".ToLowerInvariant()
if ($LockHash -cnotmatch '^[0-9a-f]{64}$') { throw "crypto provenance: malformed Cargo.lock hash: $LockHash" }
# Uncommitted or untracked crate sources mean the library is not exactly
# source_revision. The ignored target directory does not count.
$TreeStatus = "$(git -C $Root status --porcelain --untracked-files=normal -- crypto/rust)"
if ($LASTEXITCODE -ne 0) { throw "crypto provenance: cannot read the crypto/rust tree status" }
$TreeDirty = if ($TreeStatus.Trim()) { "true" } else { "false" }

Push-Location $Crate
try {
  # Run inside the crate so rustup resolves the same toolchain cargo uses.
  $Rustc = @(rustc -Vv)
  if ($LASTEXITCODE -ne 0) { throw "crypto provenance: rustc -Vv failed" }
  if ($Rustc.Count -eq 0 -or "$($Rustc[0])" -cnotmatch '^rustc ' -or -not ($Rustc -cmatch '^release: [0-9]')) {
    throw "crypto provenance: unexpected rustc -Vv output"
  }
  cargo build --locked --release
  if ($LASTEXITCODE -ne 0) { throw "crypto library build failed" }
} finally {
  Pop-Location
}

New-Item -ItemType Directory -Force -Path $Metadata | Out-Null
Copy-Item (Join-Path $Crate "target\release\private_messenger_crypto.dll") $Destination -Force

@("source_revision=$Revision", "cargo_lock_sha256=$LockHash", "source_tree_dirty=$TreeDirty") + $Rustc |
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
