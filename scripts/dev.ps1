$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$GoVersion = (Get-Content -Raw (Join-Path $Root ".go-version")).Trim()
$GoImage = "golang:${GoVersion}@sha256:672c944cfd07599b5f1bb179869270cdc94c6254e41db4d431259693cb286b82"

# An unset PRIVATE_MESSENGER_ENV means production, so the local server says
# development explicitly (tokenless loopback setup, no proxy requirement).
if (Get-Command go -ErrorAction SilentlyContinue) {
  $PreviousEnvironment = $env:PRIVATE_MESSENGER_ENV
  $env:PRIVATE_MESSENGER_ENV = "development"
  Push-Location (Join-Path $Root "server")
  try {
    go run ./cmd/messenger-server serve
  } finally {
    Pop-Location
    $env:PRIVATE_MESSENGER_ENV = $PreviousEnvironment
  }
} else {
  docker run --rm -it -p 127.0.0.1:8080:8080 -v "${Root}:/workspace" -w /workspace/server -e PRIVATE_MESSENGER_ENV=development -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_DATA_DIR=/workspace/data $GoImage go run ./cmd/messenger-server serve
}

