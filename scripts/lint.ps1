$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$GoVersion = (Get-Content -Raw (Join-Path $Root ".go-version")).Trim()
$GoImage = "golang:${GoVersion}@sha256:6c2a5538f964f1c82f97ad14988bf05de100d922d159d0e398b54c7b0ca0c6c9"

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
  $Formatted = docker run --rm -v "${Root}:/workspace" -w /workspace/server $GoImage gofmt -l .
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  if ($Formatted) {
    Write-Error "gofmt needed: $Formatted"
  }
  docker run --rm -v "${Root}:/workspace" -w /workspace/server $GoImage go vet ./...
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
  docker run --rm -v "${Root}:/workspace" -w /workspace/crypto/rust rust:1.91@sha256:867f1d1162913c401378a8504fb17fe2032c760dc316448766f150a130204aad sh -c $RustLintCommand
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
  docker run --rm -v "${Root}:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:3.44.0@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8 sh -c $FlutterLintCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
