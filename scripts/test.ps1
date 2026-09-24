$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$GoVersion = (Get-Content -Raw (Join-Path $Root ".go-version")).Trim()
$GoImage = "golang:${GoVersion}@sha256:6c2a5538f964f1c82f97ad14988bf05de100d922d159d0e398b54c7b0ca0c6c9"

$PythonCmd = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } elseif (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { $null }
if ($PythonCmd) {
  & $PythonCmd (Join-Path $Root "scripts/check-release-evidence_test.py")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $PythonCmd (Join-Path $Root "scripts/check-dart-retractions_test.py")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $PythonCmd (Join-Path $Root "scripts/check-ci-evidence_test.py")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $PythonCmd (Join-Path $Root "scripts/write-release-evidence_test.py")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $PythonCmd (Join-Path $Root "scripts/check-coverage_test.py")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command go -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "server")
  try {
    go test ./...
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally { Pop-Location }
} else {
  docker run --rm -v "${Root}:/workspace" -w /workspace/server $GoImage go test ./...
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command cargo -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "crypto/rust")
  try {
    cargo test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally { Pop-Location }
} else {
  docker run --rm -v "${Root}:/workspace" -w /workspace/crypto/rust rust:1.91@sha256:867f1d1162913c401378a8504fb17fe2032c760dc316448766f150a130204aad cargo test
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Get-Command flutter -ErrorAction SilentlyContinue) {
  Push-Location (Join-Path $Root "mobile")
  try {
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    flutter test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally { Pop-Location }
} else {
  $FlutterTestCommand = 'flutter pub get --enforce-lockfile && flutter test'
  docker run --rm -v "${Root}:/workspace" -w /workspace/mobile ghcr.io/cirruslabs/flutter:3.44.0@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8 sh -c $FlutterTestCommand
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
