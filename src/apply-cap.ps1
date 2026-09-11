# =============================================================================
#  apply-cap.ps1 - apply (and optionally watchdog) the configured charge cap
#
#  Intended to run from a scheduled task (SYSTEM, hidden) so the cap survives
#  EC resets and OEM-services overwriting it after boot - no UAC prompt.
#
#  Cap source of truth (highest priority):
#      <project>\config\autocap.txt     single integer 0..100
#  Falls back to the -Percent parameter, then to 80.
#
#  Parameters
#    -DelaySeconds           wait before the first write (let EC/OEM settle)
#    -RepeatCount            how many times to (re)apply  (default 1)
#    -RepeatIntervalSeconds  pause between repeats        (default 60)
#
#  Every iteration logs: pre-readback, SET result, post-readback. If a later
#  readback differs from the first successful one it is flagged (external
#  override / EC reset).
#
#  Requires admin (the scheduled task provides it). Exit 0 = last write ok.
# =============================================================================
param(
    [int]$Percent = 80,
    [int]$DelaySeconds = 20,
    [int]$RepeatCount = 1,
    [int]$RepeatIntervalSeconds = 60
)

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

Write-LogLine ("apply-cap start (pid $PID, delay=$DelaySeconds, repeat=$RepeatCount, interval=${RepeatIntervalSeconds}s)")

# ---- resolve target value (config file wins) -------------------------------
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

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

Import-Module $module -Force

if (-not (Test-IsAdministrator)) {
    Write-LogLine 'ERROR: not elevated - cannot touch firmware'
    exit 2
}

$firstReadback = $null
$lastOk = $false

for ($i = 1; $i -le [Math]::Max(1, $RepeatCount); $i++) {
    try {
        $pre = Invoke-EmdMethod -ClassName 'EmdAcpi_BatteryChargeRationing' -MethodName 'GetBatteryChargeRationing' -Data ([uint64]0)
        $preHex = if ($pre.Ok -and $null -ne $pre.DataOut) { '0x{0:X}' -f $pre.DataOut } else { "ERR($($pre.Error))" }

        $r = Set-EmdChargeRationing -Data ([uint64]$value) -Force
        Start-Sleep -Milliseconds 300
        $post = Invoke-EmdMethod -ClassName 'EmdAcpi_BatteryChargeRationing' -MethodName 'GetBatteryChargeRationing' -Data ([uint64]0)
        $postHex = if ($post.Ok -and $null -ne $post.DataOut) { '0x{0:X}' -f $post.DataOut } else { "ERR($($post.Error))" }

        if ($null -eq $firstReadback -and $post.Ok) { $firstReadback = $postHex }

        $note = ''
        if ($null -ne $firstReadback -and $postHex -ne $firstReadback) {
            $note = "  NOTE: readback changed vs first ($firstReadback) - possible external override/EC reset"
        }
        if ($r.Ok) {
            Write-LogLine ("[$i/$RepeatCount] SET $value OK  pre=$preHex  post=$postHex$note")
            $lastOk = $true
        } else {
            Write-LogLine ("[$i/$RepeatCount] SET $value FAILED: $($r.Error)  pre=$preHex")
            $lastOk = $false
        }
    } catch {
        Write-LogLine ("[$i/$RepeatCount] ERROR: $($_.Exception.Message)")
        $lastOk = $false
    }
    if ($i -lt $RepeatCount -and $RepeatIntervalSeconds -gt 0) { Start-Sleep -Seconds $RepeatIntervalSeconds }
}

Write-LogLine ("apply-cap done (lastOk=$lastOk)")
if ($lastOk) { exit 0 } else { exit 3 }
