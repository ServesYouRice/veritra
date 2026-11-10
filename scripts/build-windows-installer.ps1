# Local Windows installer build script for Veritra (Package W12, no CI).
# Packages the built Windows desktop application into an Inno Setup installer.
#
# Usage:
#   .\scripts\build-windows-installer.ps1
#   .\scripts\build-windows-installer.ps1 -AppDir C:\out\windows -OutDir C:\out\installer
#   .\scripts\build-windows-installer.ps1 -DryRun
#   .\scripts\build-windows-installer.ps1 -SignToolCommand 'signtool.exe sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 /f cert.pfx /p secret $f'
#
# Signing stays a placeholder until the owner acquires and configures a code-signing certificate.
[CmdletBinding()]
param(
  [string]$AppDir,
  [string]$AppVersion,
  [string]$OutDir,
  [string]$SignToolCommand,
  [string]$IsccPath,
  [switch]$BuildApp,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$IssFile = Join-Path $Root "release\windows\veritra.iss"
if (-not (Test-Path -LiteralPath $IssFile)) {
  throw "Inno Setup definition not found: $IssFile"
}

# Resolve AppVersion from mobile/pubspec.yaml if not provided
if (-not $AppVersion) {
  $Pubspec = Join-Path $Root "mobile\pubspec.yaml"
  if (Test-Path -LiteralPath $Pubspec) {
    $VersionMatch = Select-String -Path $Pubspec -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
    if ($VersionMatch) {
      $AppVersion = $VersionMatch.Matches[0].Groups[1].Value
    }
  }
}
if (-not $AppVersion) {
  $AppVersion = "0.1.0"
}

# Resolve AppDir
if (-not $AppDir) {
  $DefaultAppDir = Join-Path $Root "mobile\build\windows\x64\runner\Release"
  if (Test-Path -LiteralPath (Join-Path $DefaultAppDir "private_messenger.exe")) {
    $AppDir = $DefaultAppDir
  } elseif (Test-Path -LiteralPath (Join-Path $Root "build\windows\x64\runner\Release\private_messenger.exe")) {
    $AppDir = Join-Path $Root "build\windows\x64\runner\Release"
  } else {
    $AppDir = $DefaultAppDir
  }
}

# If AppDir does not exist or lacks binary, build it if requested, else fail unless DryRun
$Executable = Join-Path $AppDir "private_messenger.exe"
if (-not (Test-Path -LiteralPath $Executable)) {
  if ($BuildApp) {
    Write-Host "Building Windows release app via scripts\repro\build.ps1..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\repro\build.ps1") -OutDir $AppDir
    if ($LASTEXITCODE -ne 0) { throw "Windows app build failed with exit code $LASTEXITCODE" }
  } elseif (-not $DryRun) {
    throw "Windows application executable not found at '$Executable'. Run scripts\repro\build.ps1 first, or pass -BuildApp."
  }
}

# Resolve OutDir
if (-not $OutDir) {
  $OutDir = Join-Path $Root "release\windows\dist"
}
$ResolvedOutDir = [System.IO.Path]::GetFullPath($OutDir)

# Locate Inno Setup 6 compiler (iscc.exe)
if (-not $IsccPath) {
  $Command = Get-Command "iscc.exe" -ErrorAction SilentlyContinue
  if ($Command) {
    $IsccPath = $Command.Source
  } else {
    $Candidates = @(
      (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\iscc.exe"),
      (Join-Path ${env:ProgramFiles} "Inno Setup 6\iscc.exe"),
      (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\iscc.exe")
    )
    foreach ($Candidate in $Candidates) {
      if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
        $IsccPath = $Candidate
        break
      }
    }
  }
}

if (-not $IsccPath -and -not $DryRun) {
  throw "Inno Setup 6 compiler (iscc.exe) not found. Install Inno Setup 6 or pass -IsccPath <path\to\iscc.exe>."
}

# Build ISCC argument list
$IsccArgs = @(
  "/DAppDir=$AppDir",
  "/DAppVersion=$AppVersion",
  "/DOutDir=$ResolvedOutDir"
)

# Signing configuration (signing placeholder waits for owner's certificate)
if ($SignToolCommand) {
  $IsccArgs += "/DSignToolName=veritra"
  $IsccArgs += "/Sveritra=$SignToolCommand"
  Write-Host "Configured SignTool with custom signing command."
} else {
  Write-Host "No -SignToolCommand provided; building unsigned installer (signing placeholder)."
}

$IsccArgs += $IssFile

if ($DryRun) {
  Write-Host "[DryRun] Inno Setup compiler: $IsccPath"
  Write-Host "[DryRun] Arguments: $($IsccArgs -join ' ')"
  Write-Host "[DryRun] Target installer: $ResolvedOutDir\Veritra-Setup-$AppVersion-x64.exe"
  return
}

# Ensure output directory exists
if (-not (Test-Path -LiteralPath $ResolvedOutDir)) {
  New-Item -ItemType Directory -Force -Path $ResolvedOutDir | Out-Null
}

Write-Host "Running ISCC to build Windows installer..."
& $IsccPath $IsccArgs
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}

$InstallerFile = Join-Path $ResolvedOutDir "Veritra-Setup-$AppVersion-x64.exe"
if (-not (Test-Path -LiteralPath $InstallerFile)) {
  throw "Expected installer was not created at $InstallerFile"
}

$Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstallerFile).Hash.ToLowerInvariant()
$SumsFile = Join-Path $ResolvedOutDir "SHA256SUMS"
$SumLine = "$Hash  Veritra-Setup-$AppVersion-x64.exe"
Set-Content -Path $SumsFile -Value $SumLine -Encoding ascii

Write-Host "Successfully built Windows installer:"
Write-Host "  File:   $InstallerFile"
Write-Host "  SHA256: $Hash"
