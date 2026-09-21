[CmdletBinding()]
param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'CodexPictureBackground'))

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSCommandPath
$backgrounds = @(Get-ChildItem -LiteralPath $source -File | Where-Object {
  $_.Name -match '^background(?:-[1-9][0-9]*)?\.png$'
} | Sort-Object Name)
if ($backgrounds.Count -eq 0) { throw 'No background images were found.' }
$required = @('background.css', 'injector.mjs', 'start.ps1', 'stop.ps1') + @($backgrounds.Name)
foreach ($name in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $source $name))) { throw "Missing file: $name" }
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
foreach ($name in $required) {
  Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $Destination $name) -Force
}

$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = '-NoProfile -File "' + (Join-Path $Destination 'start.ps1') + '"'
$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcutPaths = @(
  (Join-Path $desktop 'Codex Picture Background.lnk'),
  (Join-Path $startMenu 'Codex Picture Background.lnk')
)
$legacyShortcutPaths = @(
  (Join-Path $desktop 'Codex Picture Background 2.lnk'),
  (Join-Path $startMenu 'Codex Picture Background 2.lnk')
)
foreach ($legacyPath in $legacyShortcutPaths) {
  if (Test-Path -LiteralPath $legacyPath) { $shortcutPaths += $legacyPath }
}
foreach ($shortcutPath in $shortcutPaths) {
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $powershell
  $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $Destination
  $shortcut.Description = 'Start Codex with a randomly selected picture background'
  $shortcut.Save()
}

Write-Output $Destination
