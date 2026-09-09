# =============================================================================
#  RunProbe2Elevated.ps1 - launch tools\probe2-elevated.ps1 elevated
#
#  Usage (normal console):
#      powershell -ExecutionPolicy Bypass -File .\tools\RunProbe2Elevated.ps1
#      powershell -ExecutionPolicy Bypass -File .\tools\RunProbe2Elevated.ps1 -AllowCalibration
#
#  -AllowCalibration additionally performs two functionally-neutral firmware
#  writes (rationing=100, read back, then rationing=0 to restore) so we can
#  decode the Set encoding. Approve the UAC prompt that appears.
# =============================================================================
param([switch]$AllowCalibration)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$inner = Join-Path $PSScriptRoot 'probe2-elevated.ps1'
$log   = Join-Path $root 'config\probe2-admin.log'
if (Test-Path $log) { Remove-Item $log -Force }

Write-Host 'Requesting administrator rights (accept the UAC prompt)...' -ForegroundColor Yellow
$argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $inner + '" -Log "' + $log + '"'
if ($AllowCalibration) { $argList += ' -AllowCalibration' }

try {
    Start-Process -FilePath powershell.exe -Verb RunAs -Wait -ArgumentList $argList
} catch {
    Write-Host "Elevation failed or was cancelled: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (Test-Path $log) {
    Write-Host ''
    Write-Host '======== probe2-admin.log ========' -ForegroundColor Green
    Get-Content -Path $log -Encoding UTF8 | Select-Object -First 400
    Write-Host ''
    Write-Host "Full log: $log"
} else {
    Write-Host 'No log produced.' -ForegroundColor Red
}
