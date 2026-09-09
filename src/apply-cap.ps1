# =============================================================================
#  apply-cap.ps1 - silently apply the configured charge cap (percent)
#
#  Intended to run from a scheduled task (as SYSTEM / elevated, hidden window)
#  so the cap is re-applied on every boot/logon without any UAC prompt.
#
#  Cap source of truth (highest priority):
#      <project>\config\autocap.txt     single integer 0..100
#  Falls back to the -Percent parameter, then to 80.
#
#  Requires admin (the scheduled task provides it). Writes a log to
#  %ProgramData%\MechrevoChargeControl\logs\apply-cap.log. Exit code 0 = ok.
# =============================================================================
param([int]$Percent = 80, [int]$DelaySeconds = 20)

$ErrorActionPreference = 'Stop'
$srcDir   = Split-Path $MyInvocation.MyCommand.Path -Parent
$root     = Split-Path $srcDir -Parent
$module   = Join-Path $srcDir 'MechrevoChargeControl.psm1'
$cfgFile  = Join-Path $root 'config\autocap.txt'
$logDir   = Join-Path $env:ProgramData 'MechrevoChargeControl\logs'
$logFile  = Join-Path $logDir 'apply-cap.log'

try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { }

function Write-LogLine {
    param([string]$M)
    try { Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $M) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

Write-LogLine "apply-cap start (pid $PID)"

# authoritative value from config file if present
$value = $null
if (Test-Path $cfgFile) {
    try {
        $txt = (Get-Content $cfgFile -Raw -ErrorAction Stop).Trim()
        $parsed = 0
        if ([int]::TryParse($txt, [ref]$parsed)) {
            if ($parsed -ge 0 -and $parsed -le 100) { $value = $parsed }
        }
    } catch { }
}
if ($null -eq $value) { $value = $Percent }
Write-LogLine "cap target = $value (source: $(if(Test-Path $cfgFile){'config\autocap.txt'}else{'parameter default'}))"

# give GCUService / EC a moment to settle on boot
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

Import-Module $module -Force

if (-not (Test-IsAdministrator)) {
    Write-LogLine 'ERROR: not elevated - cannot touch firmware'
    exit 2
}

try {
    $r = Set-EmdChargeRationing -Data ([uint64]$value) -Force
    if ($r.Ok) {
        Write-LogLine "SET rationing = $value OK (rv=$($r.ReturnValue))"
    } else {
        Write-LogLine "SET rationing = $value FAILED: $($r.Error)"
        exit 3
    }
    # read back for the log
    Start-Sleep -Milliseconds 300
    $g = Invoke-EmdMethod -ClassName 'EmdAcpi_BatteryChargeRationing' -MethodName 'GetBatteryChargeRationing' -Data ([uint64]0)
    if ($g.Ok -and $null -ne $g.DataOut) {
        Write-LogLine ("readback Get -> 0x{0:X}" -f $g.DataOut)
    } else {
        Write-LogLine "readback failed: $($g.Error)"
    }
    Write-LogLine 'apply-cap done (exit 0)'
    exit 0
} catch {
    Write-LogLine "apply-cap ERROR: $($_.Exception.Message)"
    exit 4
}
