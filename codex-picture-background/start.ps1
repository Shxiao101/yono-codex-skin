[CmdletBinding()]
param(
  [int]$PreferredPort = 9346,
  [string]$Background
)

$ErrorActionPreference = 'Stop'
$installRoot = Split-Path -Parent $PSCommandPath
$statePath = Join-Path $installRoot 'state.json'
$injectorPath = Join-Path $installRoot 'injector.mjs'
$logPath = Join-Path $installRoot 'last-run.log'
$watcherLogPath = Join-Path $installRoot 'watcher.log'
$watcherErrorPath = Join-Path $installRoot 'watcher-error.log'
$watcher = $null

function Get-CodexPackage {
  $package = Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package) { throw 'The official OpenAI Codex Windows app was not found.' }
  $manifest = Get-AppxPackageManifest -Package $package
  $application = @($manifest.Package.Applications.Application | Where-Object {
    "$($_.Executable)".Replace([char]47, [char]92) -ieq 'app\ChatGPT.exe'
  }) | Select-Object -First 1
  if (-not $application) { throw 'The Codex package entry point could not be resolved.' }
  [pscustomobject]@{
    Executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    AppUserModelId = "$($package.PackageFamilyName)!$($application.Id)"
  }
}

function Start-PackagedCodex([string]$AppUserModelId, [string[]]$Arguments) {
  if (-not ('CodexPictureBackground.PackageLauncher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexPictureBackground {
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
  }
  [ComImport, Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
  internal class ApplicationActivationManager {}
  public static class PackageLauncher {
    public static uint Launch(string id, string args) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      uint processId;
      int result = manager.ActivateApplication(id, args ?? String.Empty, 0, out processId);
      Marshal.ThrowExceptionForHR(result);
      return processId;
    }
  }
}
'@
  }
  $quoted = $Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }
  [void][CodexPictureBackground.PackageLauncher]::Launch($AppUserModelId, ($quoted -join ' '))
}

function Test-FreePort([int]$Port) {
  $listener = $null
  try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    return $true
  } catch { return $false } finally { if ($listener) { $listener.Stop() } }
}

function Find-FreePort([int]$Start) {
  foreach ($candidate in $Start..([Math]::Min(65535, $Start + 40))) {
    if (Test-FreePort $candidate) { return $candidate }
  }
  throw 'No free loopback debugging port was found.'
}

function Stop-RecordedWatcher {
  if (-not (Test-Path -LiteralPath $statePath)) { return }
  try {
    $state = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
    if ($state.injectorPid) {
      $process = Get-Process -Id ([int]$state.injectorPid) -ErrorAction SilentlyContinue
      if ($process -and $process.ProcessName -eq 'node') { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
}

function Stop-Codex([string]$Executable) {
  $processes = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -ieq $Executable } catch { $false }
  })
  foreach ($process in $processes) { try { [void]$process.CloseMainWindow() } catch {} }
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -ieq $Executable } catch { $false }
  }) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
  Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -ieq $Executable } catch { $false }
  } | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-BrowserId([int]$Port) {
  $deadline = (Get-Date).AddSeconds(75)
  do {
    try {
      $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -MaximumRedirection 0
      $uri = [Uri]$version.webSocketDebuggerUrl
      if ($uri.Host -in @('127.0.0.1', 'localhost', '::1') -and $uri.Port -eq $Port -and
          $uri.AbsolutePath -match '^/devtools/browser/([A-Za-z0-9._-]{1,200})$') { return $Matches[1] }
    } catch {}
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  throw 'Codex did not expose its loopback debugging endpoint.'
}

try {
  if ([string]::IsNullOrWhiteSpace($Background)) {
    $availableBackgrounds = @(Get-ChildItem -LiteralPath $installRoot -File | Where-Object {
      $_.Name -match '^background(?:-[1-9][0-9]*)?\.png$'
    })
    if ($availableBackgrounds.Count -eq 0) { throw 'No background images were found.' }
    $Background = ($availableBackgrounds | Get-Random).Name
  }
  if ($Background -notmatch '^background(?:-[1-9][0-9]*)?\.png$') {
    throw "Invalid background name: $Background"
  }
  $backgroundPath = Join-Path $installRoot $Background

  "$(Get-Date -Format o) START background=$Background" | Set-Content -LiteralPath $logPath -Encoding UTF8
  $node = (Get-Command node.exe -ErrorAction Stop).Source
  $nodeMajor = [int]((& $node -p 'process.versions.node').Split('.')[0])
  if ($nodeMajor -lt 22) { throw 'Node.js 22 or newer is required.' }
  if (-not (Test-Path -LiteralPath $injectorPath)) { throw 'The standalone background injector is missing.' }
  if (-not (Test-Path -LiteralPath $backgroundPath)) { throw "The selected background is missing: $Background" }

  Stop-RecordedWatcher
  $codex = Get-CodexPackage
  Stop-Codex $codex.Executable
  $port = Find-FreePort $PreferredPort
  "$(Get-Date -Format o) LAUNCH port=$port" | Add-Content -LiteralPath $logPath -Encoding UTF8
  Start-PackagedCodex $codex.AppUserModelId @('--remote-debugging-address=127.0.0.1', "--remote-debugging-port=$port")
  $browserId = Get-BrowserId $port
  "$(Get-Date -Format o) CDP browser=$browserId" | Add-Content -LiteralPath $logPath -Encoding UTF8

  & $node $injectorPath --once --port $port --browser-id $browserId --background $Background *>> $logPath
  if ($LASTEXITCODE -ne 0) { throw 'The one-shot background injection failed.' }

  & $node $injectorPath --verify --port $port --browser-id $browserId --background $Background --timeout-ms 90000 *>> $logPath
  if ($LASTEXITCODE -ne 0) { throw 'Background verification failed.' }

  $watcherArguments = @(
    $injectorPath, '--watch', '--port', "$port", '--browser-id', $browserId,
    '--background', $Background
  )
  $watcher = Start-Process -FilePath $node -ArgumentList $watcherArguments -WindowStyle Hidden `
    -RedirectStandardOutput $watcherLogPath -RedirectStandardError $watcherErrorPath -PassThru
  Start-Sleep -Milliseconds 500
  if ($watcher.HasExited) { throw 'The background watcher exited during startup.' }

  [pscustomobject]@{
    schemaVersion = 1
    port = $port
    browserId = $browserId
    injectorPid = $watcher.Id
    mode = 'watch'
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
  } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

  "$(Get-Date -Format o) SUCCESS" | Add-Content -LiteralPath $logPath -Encoding UTF8
} catch {
  if ($watcher -and -not $watcher.HasExited) {
    Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue
  }
  "$(Get-Date -Format o) ERROR $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" |
    Add-Content -LiteralPath $logPath -Encoding UTF8
  Write-Error $_
  exit 1
}
