$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")

if (Get-Command go -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "server")
  go run ./cmd/messenger-server serve
  Pop-Location
} else {
  docker run --rm -it -p 8080:8080 -v "${Root}:/workspace" -w /workspace/server -e PRIVATE_MESSENGER_ADDR=:8080 -e PRIVATE_MESSENGER_DATA_DIR=/workspace/data golang:1.25 go run ./cmd/messenger-server serve
}

