$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")

if (Get-Command go -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "server")
  try {
    $Formatted = gofmt -l .
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($Formatted) { throw "gofmt needed: $Formatted" }
    go vet ./...
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally { Pop-Location }
} else {
  $Formatted = docker run --rm -v "${Root}:/workspace" -w /workspace/server golang:1.25 gofmt -l .
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  if ($Formatted) {
    Write-Error "gofmt needed: $Formatted"
  }
  docker run --rm -v "${Root}:/workspace" -w /workspace/server golang:1.25 go vet ./...
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command cargo -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "crypto/rust")
  try {
    cargo fmt --check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    cargo clippy --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally { Pop-Location }
} else {
  $RustLintCommand = 'rustup component add rustfmt clippy >/dev/null && cargo fmt --check && cargo clippy --all-targets -- -D warnings'
  docker run --rm -v "${Root}:/workspace" -w /workspace/crypto/rust rust:1.82 sh -c $RustLintCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command flutter -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "mobile")
  try {
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    flutter analyze
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart format --set-exit-if-changed .
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally { Pop-Location }
} else {
  $FlutterLintCommand = 'flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed .'
  docker run --rm -v "${Root}:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:3.44.0 sh -c $FlutterLintCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
