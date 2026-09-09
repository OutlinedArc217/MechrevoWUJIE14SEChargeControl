# =============================================================================
#  SetChargeCap-Elevated.ps1 - set the charge cap / mode with a UAC prompt
#
#  Usage from a NORMAL console:
#    powershell -ExecutionPolicy Bypass -File .\tools\SetChargeCap-Elevated.ps1 -Percent 80
#    powershell -ExecutionPolicy Bypass -File .\tools\SetChargeCap-Elevated.ps1 -Profile Stationary
#
#  Approve the UAC prompt. Log + readback are printed afterwards. WARNING: this
#  really changes firmware behaviour - only run it after the calibration probe
#  confirmed the encoding (see RunProbe2Elevated.ps1 -AllowCalibration).
# =============================================================================
param(
    [ValidateRange(0,100)][int]$Percent,
    [ValidateSet('Full','Balanced','Stationary')][string]$Profile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cli    = Join-Path $root 'src\chargectl.ps1'
$runner = Join-Path $PSScriptRoot 'cc-elevated-runner.ps1'

$cmdTokens = @()
if ($PSBoundParameters.ContainsKey('Percent')) { $cmdTokens = @('set-limit','-Percent',"$Percent") }
elseif ($PSBoundParameters.ContainsKey('Profile')) { $cmdTokens = @('set-mode','-Profile',$Profile) }
else { throw 'Provide -Percent (0..100; 0 = limit inactive/charge to full) or -Profile Full|Balanced|Stationary' }
$cmdTokens += '-Force'

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root ("config\cc-set-$ts.log")

$argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '" -Cli "' + $cli + '"'
$argList += ' -CmdTokens "' + ($cmdTokens -join ',') + '"'
$argList += ' -LogFile "' + $log + '"'

Write-Host ('About to run (elevated):  ' + ($cmdTokens -join ' ')) -ForegroundColor Yellow
Write-Host 'A UAC prompt will appear - accept it to continue.' -ForegroundColor Yellow
try {
    Start-Process -FilePath powershell.exe -Verb RunAs -Wait -ArgumentList $argList
} catch {
    Write-Host "Elevation failed or was cancelled: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if (Test-Path $log) {
    Write-Host ''
    Write-Host '======== result ========' -ForegroundColor Green
    Get-Content -Path $log -Encoding UTF8 | Select-Object -Last 40
    Write-Host ''
    Write-Host "Full log: $log"
} else {
    Write-Host 'No log produced - the elevated run probably failed.' -ForegroundColor Red
}
