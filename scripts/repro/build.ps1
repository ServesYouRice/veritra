# One reproducible build of the unsigned Windows app, from this checkout.
#
#   scripts\repro\build.ps1 -OutDir C:\out\a
#
# Needs the pinned Rust (rust-toolchain.toml), Flutter 3.44.0 and Visual Studio
# 2022 Build Tools with the "Desktop development with C++" workload. NOT run on
# a Windows machine yet: this is a draft for the owner's first Windows build
# (testing/evidence/W12-release-engineering.md). Signing is never done here.
param([Parameter(Mandatory = $true)][string]$OutDir)
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

# One timestamp for the whole build: the commit's own time, never "now".
$Epoch = "$(git -C $Root log -1 --format=%ct HEAD)".Trim()
if ($LASTEXITCODE -ne 0 -or $Epoch -cnotmatch '^[0-9]+$') { throw "cannot read the commit time" }
$env:SOURCE_DATE_EPOCH = $Epoch
$env:CARGO_INCREMENTAL = "0"
# Keep build paths out of the binaries and make the linker stamp a hash, not
# the clock (/Brepro).
$Sysroot = "$(rustc --print sysroot)".Trim()
$CargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE ".cargo" }
$env:RUSTFLAGS = "--remap-path-prefix=$Root=/veritra --remap-path-prefix=$CargoHome=/cargo --remap-path-prefix=$Sysroot=/rustc -C link-arg=/Brepro"
$env:LDFLAGS = "/Brepro"

$PinRust = (Select-String -Path (Join-Path $Root "rust-toolchain.toml") -Pattern '^channel *= *"(.*)"').Matches[0].Groups[1].Value
$GotRust = ("$(rustc --version)" -split ' ')[1]
if ($GotRust -ne $PinRust) { throw "rustc $GotRust, pinned $PinRust" }
$PinFlutter = (Select-String -Path (Join-Path $Root "mobile\pubspec.yaml") -Pattern '^  flutter: *(.*)$').Matches[0].Groups[1].Value.Trim()
$GotFlutter = (flutter --version --machine | ConvertFrom-Json).frameworkVersion
if ($GotFlutter -ne $PinFlutter) { throw "flutter $GotFlutter, pinned $PinFlutter" }

& (Join-Path $Root "scripts\build-desktop-crypto.ps1")
Push-Location (Join-Path $Root "mobile")
try {
  flutter pub get --enforce-lockfile
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
  # Release build only: the demo entry point is never built here.
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }
} finally { Pop-Location }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item -Recurse -Force (Join-Path $Root "mobile\build\windows\x64\runner\Release\*") $OutDir
# Sorted digest list, the same shape as the Linux and Android scripts write.
$Out = (Resolve-Path $OutDir).Path
Get-ChildItem -Recurse -File $Out | Where-Object { $_.Name -ne "SHA256SUMS" } |
  ForEach-Object { [pscustomobject]@{ Rel = $_.FullName.Substring($Out.Length + 1).Replace('\', '/'); Hash = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() } } |
  Sort-Object -Property Rel -CaseSensitive |
  ForEach-Object { "$($_.Hash)  $($_.Rel)" } |
  Set-Content -Encoding ascii -Path (Join-Path $Out "SHA256SUMS")
Write-Host "built windows into $Out"
