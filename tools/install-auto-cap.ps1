# =============================================================================
#  install-auto-cap.ps1 - install/uninstall the "auto apply charge cap" tasks
#
#  Usage from a NORMAL console (self-elevates; approve the UAC prompt once):
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1              # 80%
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Percent 60
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Status
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Uninstall
#
#  Two scheduled tasks are created (both run as SYSTEM, hidden, no UAC):
#    MechrevoChargeCap       - at boot + at logon: applies the cap, then keeps
#                              re-applying it every 60 s for 15 minutes (watchdog
#                              against EC reset / OEM service overwriting it)
#    MechrevoChargeCap-Keep  - every 3 hours: single re-apply (self-heal)
#
#  The cap value lives in config\autocap.txt (single int 0..100); edit it to
#  change the cap later, or re-run this installer with -Percent. The installer
#  also applies the cap immediately (it is already elevated).
# =============================================================================
param(
    [ValidateRange(0,100)][int]$Percent = 80,
    [switch]$Uninstall,
    [switch]$Status
)

$TaskMain = 'MechrevoChargeCap'
$TaskKeep = 'MechrevoChargeCap-Keep'
$root     = Split-Path $PSScriptRoot -Parent
$script   = Join-Path $root 'src\apply-cap.ps1'
$cfgFile  = Join-Path $root 'config\autocap.txt'
$logFile  = Join-Path $env:ProgramData 'MechrevoChargeControl\logs\apply-cap.log'

# ---- self-elevation --------------------------------------------------------
$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr  = New-Object Security.Principal.WindowsPrincipal($id)
$admin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $admin) {
    Write-Host 'Requesting administrator rights (accept the UAC prompt)...' -ForegroundColor Yellow
    $rel = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"'
    if ($Uninstall) { $rel += ' -Uninstall' }
    elseif ($Status) { $rel += ' -Status' }
    else { $rel += ' -Percent ' + $Percent }
    $p = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList $rel
    exit $p.ExitCode
}

function Show-OneTask {
    param([string]$Name)
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "  $Name : NOT installed"; return }
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    Write-Host "  $Name : $($t.State)  last=$($info.LastRunTime)  result=$($info.LastTaskResult)  next=$($info.NextRunTime)"
}

# ---- Status ----------------------------------------------------------------
if ($Status) {
    Write-Host 'Scheduled tasks:'
    Show-OneTask $TaskMain
    Show-OneTask $TaskKeep
    if (Test-Path $cfgFile) { Write-Host "  cap config: $(Get-Content $cfgFile -Raw) (config\autocap.txt)" } else { Write-Host '  cap config: missing' }
    if (Test-Path $logFile) { Write-Host ''; Write-Host '--- last apply-cap log ---'; Get-Content $logFile -Tail 10 }
    exit 0
}

# ---- Uninstall -------------------------------------------------------------
if ($Uninstall) {
    foreach ($n in @($TaskMain, $TaskKeep)) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if ($t) { Unregister-ScheduledTask -TaskName $n -Confirm:$false | Out-Null; Write-Host "Removed task '$n'." -ForegroundColor Green }
        else { Write-Host "Task '$n' was not installed." }
    }
    Write-Host "Note: kept $cfgFile (delete it manually if you no longer need it)."
    exit 0
}

# ---- (re)install -----------------------------------------------------------
try { Set-Content -Path $cfgFile -Value "$Percent" -Encoding ASCII -ErrorAction Stop; Write-Host "Saved cap $Percent% to $cfgFile" } catch { Write-Warning "could not write $cfgFile : $($_.Exception.Message)" }

$baseArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$ok = $true

# --- task 1: boot + logon, with a 15-minute watchdog ---
try {
    $a1 = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($baseArgs + ' -DelaySeconds 20 -RepeatCount 15 -RepeatIntervalSeconds 60')
    $t1 = @(New-ScheduledTaskTrigger -AtStartup)
    try { $t1 += New-ScheduledTaskTrigger -AtLogOn } catch { }
    Register-ScheduledTask -TaskName $TaskMain -Action $a1 -Trigger $t1 -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "Registered '$TaskMain' (boot + logon, 15-min watchdog)." -ForegroundColor Green
} catch { Write-Warning "could not register '$TaskMain': $($_.Exception.Message)"; $ok = $false }

# --- task 2: every 3 hours, single apply (self-heal) ---
try {
    $a2 = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($baseArgs + ' -DelaySeconds 0 -RepeatCount 1')
    $t2 = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) `
            -RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $TaskKeep -Action $a2 -Trigger $t2 -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "Registered '$TaskKeep' (every 3 hours)." -ForegroundColor Green
} catch { Write-Warning "could not register '$TaskKeep': $($_.Exception.Message)"; $ok = $false }

# --- apply immediately (we are already elevated) ---
Write-Host 'Applying cap now...' -ForegroundColor Yellow
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -DelaySeconds 0 -RepeatCount 1 | Out-Null
    if (Test-Path $logFile) { Get-Content $logFile -Tail 4 | ForEach-Object { Write-Host "  $_" } }
} catch { Write-Warning "immediate apply failed: $($_.Exception.Message)" }

Write-Host ''
Write-Host 'Manage:' -ForegroundColor Cyan
Write-Host '  change cap : edit config\autocap.txt  (single int 0..100), or re-run with -Percent <new>'
Write-Host '  check      : .\tools\install-auto-cap.ps1 -Status'
Write-Host '  remove     : .\tools\install-auto-cap.ps1 -Uninstall'
if (-not $ok) { exit 1 }
