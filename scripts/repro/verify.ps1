# Builds the Windows app twice, each from a clean copy of HEAD in its own
# directory, and compares the digest lists. Exit 0 only if byte-identical.
# Commit first. Draft: not run on a Windows machine yet.
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Work = Join-Path ([IO.Path]::GetTempPath()) ("veritra-repro-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
try {
  foreach ($run in "a", "b") {
    $src = Join-Path $Work "$run\src"
    git -C $Root worktree add --detach -q $src HEAD
    if ($LASTEXITCODE -ne 0) { throw "worktree failed" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src "scripts\repro\build.ps1") -OutDir (Join-Path $Work "$run\out")
    if ($LASTEXITCODE -ne 0) { throw "build $run failed" }
  }
  $a = Get-Content (Join-Path $Work "a\out\SHA256SUMS")
  $b = Get-Content (Join-Path $Work "b\out\SHA256SUMS")
  $diff = Compare-Object $a $b
  if ($diff) { $diff | Format-Table | Out-String | Write-Host; throw "builds differ" }
  Write-Host "identical ($($a.Count) files)"
} finally {
  foreach ($run in "a", "b") { git -C $Root worktree remove --force (Join-Path $Work "$run\src") 2>$null }
  git -C $Root worktree prune
  Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
