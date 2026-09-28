# Installation contract: preserve user assets and restore program files on failure.
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-skin-install-' + [guid]::NewGuid())
$package = Join-Path $testRoot 'package'
$destination = Join-Path $testRoot 'installed skin'
function Assert($condition, $message) { if (-not $condition) { throw $message } }
try {
  New-Item -ItemType Directory -Path $package -Force | Out-Null
  foreach ($name in @('install.ps1', 'start.ps1', 'stop.ps1', 'injector.mjs', 'background.css', 'background.png')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $package
  }
  & (Join-Path $package 'install.ps1') -Destination $destination -NoShortcuts
  Assert (Test-Path (Join-Path $destination 'background.png')) 'First install omitted background.'
  $userCss = ':root.codex-picture-background { --picture-violet: #abcdef; }'
  Set-Content (Join-Path $destination 'user.css') $userCss
  $customImage = [byte[]](1..255 * 8)
  [IO.File]::WriteAllBytes((Join-Path $destination 'background.png'), $customImage)
  [IO.File]::WriteAllBytes((Join-Path $destination 'background-9.png'), $customImage)
  $oldCss = (Get-Content (Join-Path $destination 'background.css') -Raw) + "`n/* old local edit */"
  Set-Content (Join-Path $destination 'background.css') $oldCss
  & (Join-Path $package 'install.ps1') -Destination $destination -NoShortcuts
  Assert ((Get-Content (Join-Path $destination 'user.css') -Raw).Trim() -eq $userCss) 'User CSS changed.'
  Assert ([Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes((Join-Path $destination 'background.png')), $customImage)) 'Existing background overwritten.'
  Assert (Test-Path (Join-Path $destination 'background-9.png')) 'Additional background removed.'
  Copy-Item (Join-Path $package 'background.png') (Join-Path $package 'background-2.png')
  & (Join-Path $package 'install.ps1') -Destination $destination -NoShortcuts
  Assert (Test-Path (Join-Path $destination 'background-2.png')) 'New default background not added.'
  $backups = Get-ChildItem (Join-Path $destination 'backups') -Directory
  Assert (@($backups | Where-Object { (Test-Path (Join-Path $_.FullName 'background.css')) -and (Get-Content (Join-Path $_.FullName 'background.css') -Raw).Contains('old local edit') }).Count -eq 1) 'Edited base CSS not backed up.'
  $before = Get-Content (Join-Path $destination 'injector.mjs') -Raw
  Set-Content (Join-Path $package 'injector.mjs') 'process.exit(1);'
  $failed = $false
  try { & (Join-Path $package 'install.ps1') -Destination $destination -NoShortcuts } catch { $failed = $true }
  Assert $failed 'Broken update reported success.'
  Assert ((Get-Content (Join-Path $destination 'injector.mjs') -Raw) -eq $before) 'Failed update did not restore injector.'
  Assert ((Get-Content (Join-Path $destination 'user.css') -Raw).Trim() -eq $userCss) 'Rollback changed user CSS.'
  Write-Output 'INSTALL_TESTS_OK'
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\codex-skin-install-'
  if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory.' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
