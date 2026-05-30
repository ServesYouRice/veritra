$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")

if (Get-Command go -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "server")
  go test ./...
  Pop-Location
} else {
  docker run --rm -v "${Root}:/workspace" -w /workspace/server golang:1.25 go test ./...
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command cargo -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "crypto/rust")
  cargo test
  Pop-Location
} else {
  docker run --rm -v "${Root}:/workspace" -w /workspace/crypto/rust rust:1.82 cargo test
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command flutter -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "mobile")
  flutter pub get
  flutter test
  Pop-Location
} else {
  $FlutterTestCommand = 'flutter pub get && flutter test'
  docker run --rm -v "${Root}:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:stable sh -c $FlutterTestCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
