# =============================================================================
#  RunProbeElevated.ps1 - launch tools\probe-elevated.ps1 with elevation
#
#  Run from a NORMAL console:
#      powershell -ExecutionPolicy Bypass -File .\tools\RunProbeElevated.ps1
#
#  A UAC prompt will appear - click Yes. The elevated probe runs (read-only)
#  and writes its transcript to config\probe-admin.log; this script prints the
#  tail of that log afterwards.
# =============================================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$inner = Join-Path $PSScriptRoot 'probe-elevated.ps1'
$log   = Join-Path $root 'config\probe-admin.log'

if (-not (Test-Path $inner)) { throw "missing: $inner" }
if (Test-Path $log) { Remove-Item $log -Force }

Write-Host 'Requesting administrator rights (accept the UAC prompt)...' -ForegroundColor Yellow
try {
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $inner + '" -Log "' + $log + '"'
    Start-Process -FilePath powershell.exe -Verb RunAs -Wait -ArgumentList $argList
} catch {
    Write-Host "Elevation failed or was cancelled: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
if (Test-Path $log) {
    Write-Host '======== probe-admin.log ========' -ForegroundColor Green
    Get-Content -Path $log -Encoding UTF8 | Select-Object -First 400
    Write-Host ''
    Write-Host "Full log: $log"
} else {
    Write-Host 'No log produced - the elevated run probably failed before writing.' -ForegroundColor Red
}
