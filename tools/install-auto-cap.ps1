# =============================================================================
#  install-auto-cap.ps1 - register/unregister the "auto apply charge cap"
#  scheduled task for this project
#
#  Usage from a NORMAL console (it self-elevates; approve the UAC prompt once):
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1            # install with 80%
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Percent 60
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Status     # show task state
#      powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Uninstall  # remove task
#
#  After install the task runs silently at every boot/logon (as SYSTEM,
#  no visible window, no UAC) and applies the cap stored in config\autocap.txt.
#  Change the cap later by editing config\autocap.txt (single int 0..100) or by
#  re-running this installer with a new -Percent.
# =============================================================================
param(
    [ValidateRange(0,100)][int]$Percent = 80,
    [switch]$Uninstall,
    [switch]$Status
)

$TaskName = 'MechrevoChargeCap'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'src\apply-cap.ps1'
$cfgFile = Join-Path $root 'config\autocap.txt'

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

# ---- Status ----------------------------------------------------------------
if ($Status) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "Task '$TaskName' is NOT installed."; exit 0 }
    Write-Host "Task: $($t.TaskPath)$($t.TaskName)"
    Write-Host "State: $($t.State)"
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($info) {
        Write-Host "LastRunTime : $($info.LastRunTime)"
        Write-Host "LastTaskResult : $($info.LastTaskResult)"
        Write-Host "NextRunTime : $($info.NextRunTime)"
    }
    $log = Join-Path $env:ProgramData 'MechrevoChargeControl\logs\apply-cap.log'
    if (Test-Path $log) { Write-Host ''; Write-Host '--- last apply-cap log ---'; Get-Content $log -Tail 8 }
    exit 0
}

# ---- Uninstall -------------------------------------------------------------
if ($Uninstall) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
        Write-Host "Task '$TaskName' unregistered." -ForegroundColor Green
    } else {
        Write-Host "Task '$TaskName' was not installed."
    }
    if (Test-Path $cfgFile) { Write-Host "Note: kept $cfgFile (delete manually if you no longer need it)." }
    exit 0
}

# ---- (re)install -----------------------------------------------------------
# persist desired percent as the source of truth for apply-cap.ps1
try { Set-Content -Path $cfgFile -Value "$Percent" -Encoding ASCII -ErrorAction Stop; Write-Host "Saved cap $Percent% to $cfgFile" } catch { Write-Warning "could not write $cfgFile : $($_.Exception.Message)" }

$actionArg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArg
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -MultipleInstances IgnoreNew `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$triggers = @()
$triggers += New-ScheduledTaskTrigger -AtStartup
try {
    # fires at any user logon as well; not critical if unsupported on some builds
    $triggers += New-ScheduledTaskTrigger -AtLogOn
} catch { }

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "Task '$TaskName' registered (runs as SYSTEM at boot/logon)." -ForegroundColor Green
    Write-Host "It applies the cap from $cfgFile (= $Percent%)."
    Write-Host 'To change later:  .\tools\install-auto-cap.ps1 -Percent <new>' -ForegroundColor Cyan
    Write-Host 'To remove:        .\tools\install-auto-cap.ps1 -Uninstall' -ForegroundColor Cyan
    Write-Host 'To inspect:       .\tools\install-auto-cap.ps1 -Status' -ForegroundColor Cyan
} catch {
    Write-Error "Register-ScheduledTask failed: $($_.Exception.Message)"
    exit 1
}
