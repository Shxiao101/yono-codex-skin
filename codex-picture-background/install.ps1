[CmdletBinding()]
param(
  [string]$Destination = (Join-Path $env:LOCALAPPDATA 'CodexPictureBackground'),
  [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSCommandPath
$Destination = [IO.Path]::GetFullPath($Destination)
if ($Destination.TrimEnd('\') -ieq $source.TrimEnd('\')) { throw 'Destination must differ from source.' }
$backgrounds = @(Get-ChildItem -LiteralPath $source -File | Where-Object {
  $_.Name -match '^background(?:-[1-9][0-9]*)?\.png$'
} | Sort-Object Name)
if ($backgrounds.Count -eq 0) { throw 'No background images were found.' }
$programs = @('background.css', 'injector.mjs', 'start.ps1', 'stop.ps1')
$required = $programs + @($backgrounds.Name)
foreach ($name in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $source $name))) { throw "Missing file: $name" }
}

$node = (Get-Command node.exe -ErrorAction Stop).Source
if ([int]((& $node -p 'process.versions.node').Split('.')[0]) -lt 22) { throw 'Node.js 22 or newer is required.' }
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$logPath = Join-Path $Destination 'update.log'
$statePath = Join-Path $Destination 'state.json'
$injector = Join-Path $Destination 'injector.mjs'
$backup = Join-Path $Destination ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'))
$changed = @()
$live = $false
$oldWatcher = $null
$newWatcher = $null
$stopped = $false
$state = $null
$step = 'inspect session'
"$(Get-Date -Format o) UPDATE source=$source" | Set-Content -LiteralPath $logPath -Encoding UTF8

function Test-Session {
  try {
    $endpoint = Invoke-RestMethod -Uri "http://127.0.0.1:$($state.port)/json/version" -TimeoutSec 2 -MaximumRedirection 0
    return $endpoint.webSocketDebuggerUrl -eq "ws://127.0.0.1:$($state.port)/devtools/browser/$($state.browserId)"
  } catch { return $false }
}

function Invoke-Injection {
  & $node $injector --once --port $state.port --browser-id $state.browserId --background $state.background --timeout-ms 15000 *>> $logPath
  if ($LASTEXITCODE -ne 0) { throw 'Background injection failed.' }
  & $node $injector --verify --port $state.port --browser-id $state.browserId --background $state.background --timeout-ms 15000 *>> $logPath
  if ($LASTEXITCODE -ne 0) { throw 'Background verification failed.' }
}

function Start-Watcher {
  $watcher = Start-Process -FilePath $node -ArgumentList @(
    ('"' + $injector + '"'), '--watch', '--port', $state.port,
    '--browser-id', $state.browserId, '--background', $state.background
  ) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Destination 'watcher.log') `
    -RedirectStandardError (Join-Path $Destination 'watcher-error.log') -PassThru
  Start-Sleep -Milliseconds 500
  if ($watcher.HasExited) { throw 'Background watcher exited during startup.' }
  return $watcher
}

try {
  if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$state.injectorPid)"
    if ($candidate) {
      # Match the installed script as well as the PID before stopping a process.
      $command = $candidate.CommandLine.Replace('/', '\')
      $pattern = '(?:^|[\s"])' + [regex]::Escape($injector.Replace('/', '\')) + '(?:[\s"]|$)'
      if ($candidate.Name -ne 'node.exe' -or $command -notmatch $pattern) { throw 'Recorded watcher belongs to another process.' }
      $oldWatcher = $candidate
      # Pre-1.3 state omitted the background; recover it from the owned watcher.
      if (-not $state.background) {
        if ($command -notmatch '--background\s+(background(?:-[1-9][0-9]*)?\.png)') { throw 'Legacy watcher has no background argument.' }
        $state | Add-Member -NotePropertyName background -NotePropertyValue $Matches[1]
      }
    }
    $live = Test-Session
    if ($live -and ($state.background -notmatch '^background(?:-[1-9][0-9]*)?\.png$')) { throw 'Active session has no valid background filename.' }
  }
  $step = 'backup'
  $files = $programs + @($backgrounds.Name | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Destination $_)) })
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  foreach ($name in $files) {
    $target = Join-Path $Destination $name
    if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name) }
  }
  if (Test-Path -LiteralPath $statePath) { Copy-Item -LiteralPath $statePath -Destination (Join-Path $backup 'state.json') }
  $step = 'stop watcher'
  if ($oldWatcher) { Stop-Process -Id $oldWatcher.ProcessId -ErrorAction Stop; $stopped = $true }
  $step = 'copy files'
  foreach ($name in $files) {
    $changed += $name
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $Destination $name) -Force
  }
  $step = 'validate assets'
  & $node $injector --self-test *>> $logPath
  if ($LASTEXITCODE -ne 0) { throw 'Installed asset validation failed.' }
  if ($live) {
    $step = 'apply and verify'
    Invoke-Injection
    $newWatcher = Start-Watcher
    $state.injectorPid = $newWatcher.Id
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  }
  $step = 'shortcuts'
  if (-not $NoShortcuts) {

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
  }
  if (-not $live -and (Test-Path -LiteralPath $statePath)) { Remove-Item -LiteralPath $statePath }
  "$(Get-Date -Format o) SUCCESS live=$live backup=$backup" | Add-Content -LiteralPath $logPath
  Write-Output "Installed: $Destination"
  Write-Output "Backup: $backup. Move custom base-CSS edits into user.css; backgrounds and user.css are preserved."
  if ($live) { Write-Output 'Updated and verified in the running app.' }
  else { Write-Output 'Files installed. Launch Codex Picture Background to apply and verify.' }
} catch {
  $failure = $_
  "$(Get-Date -Format o) ERROR step=$step $failure" | Add-Content -LiteralPath $logPath
  if ($newWatcher -and -not $newWatcher.HasExited) { Stop-Process -Id $newWatcher.Id -ErrorAction SilentlyContinue }
  foreach ($name in $changed) {
    $target = Join-Path $Destination $name
    $saved = Join-Path $backup $name
    if (Test-Path -LiteralPath $saved) { Copy-Item -LiteralPath $saved -Destination $target -Force }
    elseif (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target }
  }
  if ($stopped -and (Test-Session)) {
    try {
      Invoke-Injection
      $restored = Start-Watcher
      $state.injectorPid = $restored.Id
      $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
      'Previous skin and watcher restored.' | Add-Content -LiteralPath $logPath
    } catch { "RESTORE ERROR $_" | Add-Content -LiteralPath $logPath }
  }
  throw "Update failed at $step. $failure Log: $logPath; backup: $backup"
}
