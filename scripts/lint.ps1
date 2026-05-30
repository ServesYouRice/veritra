$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")

if (Get-Command go -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "server")
  $Formatted = gofmt -l .
  if ($Formatted) {
    throw "gofmt needed: $Formatted"
  }
  go vet ./...
  Pop-Location
} else {
  $GoLintCommand = 'gofmt -l . > /tmp/private-messenger-gofmt.txt && test ! -s /tmp/private-messenger-gofmt.txt && go vet ./...'
  docker run --rm -v "${Root}:/workspace" -w /workspace/server golang:1.25 sh -c $GoLintCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command cargo -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "crypto/rust")
  cargo fmt --check
  cargo clippy --all-targets -- -D warnings
  Pop-Location
} else {
  $RustLintCommand = 'rustup component add rustfmt clippy >/dev/null && cargo fmt --check && cargo clippy --all-targets -- -D warnings'
  docker run --rm -v "${Root}:/workspace" -w /workspace/crypto/rust rust:1.82 sh -c $RustLintCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command flutter -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "mobile")
  flutter pub get
  flutter analyze
  Pop-Location
} else {
  $FlutterLintCommand = 'flutter pub get && flutter analyze'
  docker run --rm -v "${Root}:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:stable sh -c $FlutterLintCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
