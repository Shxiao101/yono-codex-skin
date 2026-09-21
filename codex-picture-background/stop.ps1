$ErrorActionPreference = 'SilentlyContinue'
$installRoot = Split-Path -Parent $PSCommandPath
$statePath = Join-Path $installRoot 'state.json'
$injectorPath = Join-Path $installRoot 'injector.mjs'
if (-not (Test-Path -LiteralPath $statePath)) { exit 0 }
$state = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
$node = (Get-Command node.exe).Source
if ($state.port -and $state.browserId -and (Test-Path -LiteralPath $injectorPath)) {
  & $node $injectorPath --remove --port ([int]$state.port) --browser-id "$($state.browserId)"
}
if ($state.injectorPid) {
  $process = Get-Process -Id ([int]$state.injectorPid)
  if ($process -and $process.ProcessName -eq 'node') { Stop-Process -Id $process.Id -Force }
}
Remove-Item -LiteralPath $statePath -Force
