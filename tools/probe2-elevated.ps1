# =============================================================================
#  probe2-elevated.ps1 - ADMINISTRATIVE firmware probe (instance based)
#
#  Discovery (v1): EmdAcpi_* methods must be called THROUGH the WMI instance
#  ACPI\PNP0C14\HWMI_0 - class-level calls are rejected.
#
#  This v2 probe:
#    1) maps each Get* method's response over a wide Data sweep (read-only);
#    2) with -AllowCalibration also performs two FUNCTIONALLY NEUTRAL writes to
#       decode the Set encoding: Set rationing = 100 (still = charge to full),
#       read back, then Set rationing = 0 (restore, = limit inactive/100%).
#       Nothing else is written.
#
#  Output is a transcript log. Run it via tools\RunProbe2Elevated.ps1.
# =============================================================================
param(
    [switch]$AllowCalibration,
    [string]$Log = ''
)

$ErrorActionPreference = 'Continue'
$ns = 'root\WMI'
if (-not $Log) {
    $Log = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\probe2-admin.log'
}

$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr  = New-Object Security.Principal.WindowsPrincipal($id)
$admin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

try { Start-Transcript -Path $Log -Force -ErrorAction Stop | Out-Null } catch { }

"=============================================================="
"probe2-elevated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
"Elevated: $admin   User: $($id.Name)"
"=============================================================="

function Get-Inst { param([string]$Class)
    try { return @(Get-CimInstance -Namespace $ns -ClassName $Class -ErrorAction Stop) } catch { return @() }
}

function Call-Inst {
    param($Instance, [string]$Method, [uint64]$Data)
    try {
        $r = $Instance | Invoke-CimMethod -MethodName $Method -Arguments @{ Data = $Data } -ErrorAction Stop
        return [pscustomobject]@{ Ok=$true; Out=$(if($null -ne $r.Data){$r.Data}else{$null}); Rv=$r.ReturnValue }
    } catch {
        return [pscustomobject]@{ Ok=$false; Out=$null; Rv=$null; Err=$_.Exception.Message }
    }
}

# ---------------- read matrix ----------------
$classes = @(
    @{ C='EmdAcpi_BatteryChargeRationing'; M=@('GetBatteryChargeRationing') },
    @{ C='EmdAcpi_BatteryInfo';             M=@('GetBatteryBasicInfo','GetBatteryRealtimeInfo','GetBatteryLifecapacity') },
    @{ C='EmdAcpi_ECInformation';           M=@('GetEcVersion','GetPdVersion','GetCpuTemperature') }
)
$sweep = @([uint64]0,[uint64]1,[uint64]2,[uint64]3,[uint64]4,[uint64]5,[uint64]6,[uint64]7,[uint64]8,
           [uint64]9,[uint64]10,[uint64]16,[uint64]32,[uint64]64,[uint64]80,[uint64]100,[uint64]128,
           [uint64]256,[uint64]1024,[uint64]4096,[uint64]65536,[uint64]1048576,[uint64]16777216)

""
"================ read matrix (instance-level, read-only) ================"
foreach ($c in $classes) {
    $insts = Get-Inst $c.C
    if ($insts.Count -eq 0) { "  $($c.C): NO instance (not elevated?)"; continue }
    $inst = $insts[0]
    "----- $($c.C)  [InstanceName=$($inst.InstanceName)] -----"
    foreach ($m in $c.M) {
        $line = @()
        foreach ($v in $sweep) {
            $r = Call-Inst $inst $m $v
            if ($r.Ok) { $line += ('in=0x{0:X}->0x{1:X}' -f $v, $r.Out) }
            else { $line += ('in=0x{0:X}->ERR' -f $v) }
        }
        "  $m"
        $line -join ' | '
    }
}

# ---------------- calibration (optional, writes) ----------------
if ($AllowCalibration) {
    ""
    "================ calibration (TWO neutral writes: 100 then restore 0) ================"
    $insts = Get-Inst 'EmdAcpi_BatteryChargeRationing'
    if ($insts.Count -eq 0) { "  NO instance - abort calibration"; Stop-Transcript | Out-Null; exit 0 }
    $inst = $insts[0]

    $r0 = Call-Inst $inst 'GetBatteryChargeRationing' ([uint64]0)
    "before: Get -> OK=$($r0.Ok) out=0x$(if($r0.Ok){'{0:X}' -f $r0.Out}else{'?'})"

    $r1 = Call-Inst $inst 'SetBatteryChargeRationing' ([uint64]100)
    "SET Data=100 -> OK=$($r1.Ok) rv=$($r1.Rv) out=0x$(if($r1.Ok -and $null -ne $r1.Out){'{0:X}' -f $r1.Out}else{'?'})"
    Start-Sleep -Milliseconds 400
    $r2 = Call-Inst $inst 'GetBatteryChargeRationing' ([uint64]0)
    "after SET 100, Get -> OK=$($r2.Ok) out=0x$(if($r2.Ok){'{0:X}' -f $r2.Out}else{'?'})   (expect 100 => Data == percent, plain)"

    $r3 = Call-Inst $inst 'SetBatteryChargeRationing' ([uint64]0)
    "SET Data=0 (restore) -> OK=$($r3.Ok) rv=$($r3.Rv)"
    Start-Sleep -Milliseconds 400
    $r4 = Call-Inst $inst 'GetBatteryChargeRationing' ([uint64]0)
    "after SET 0, Get -> OK=$($r4.Ok) out=0x$(if($r4.Ok){'{0:X}' -f $r4.Out}else{'?'})   (expect 0 = limit inactive)"
} else {
    ""
    "Calibration SKIPPED (no -AllowCalibration)."
}

""
"Done. Log: $Log"
try { Stop-Transcript | Out-Null } catch { }
