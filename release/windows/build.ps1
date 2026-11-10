# Convenience wrapper to build the Windows installer (Package W12, no CI).
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

$Script = Join-Path $PSScriptRoot "..\..\scripts\build-windows-installer.ps1"
& $Script @PSBoundParameters
