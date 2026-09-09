# =============================================================================
#  probe-elevated.ps1 - ADMINISTRATIVE, READ-ONLY firmware probe
#
#  This script must run elevated. It only performs "Get*" method calls and
#  instance enumeration - nothing is written to the EC/firmware.
#
#  It tries three invocation styles for every method:
#    1) class-level Invoke-CimMethod with a UInt64 Data word
#    2) instance-level Invoke-CimMethod (on any enumerable instance)
#  and records full error text + HRESULT for every failure so we can tell
#  "access denied" (needs another account / driver) from "invalid parameter"
#  (wrong Data layout) from "success".
#
#  Run it via tools\RunProbeElevated.ps1 (UAC prompt) or manually from an
#  elevated console. Output is a transcript log (path via -Log).
# =============================================================================
param([string]$Log = '')

$ErrorActionPreference = 'Continue'
$ns = 'root\WMI'
if (-not $Log) {
    $Log = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\probe-admin.log'
}

# confirm elevation
$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr  = New-Object Security.Principal.WindowsPrincipal($id)
$admin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

try { Start-Transcript -Path $Log -Force -ErrorAction Stop | Out-Null } catch { Write-Warning "transcript failed: $($_.Exception.Message)" }

"======================================================================"
"probe-elevated started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
"Elevated: $admin   User: $($id.Name)"
( whoami /groups | Select-String -Pattern 'S-1-16-' | ForEach-Object { $_.Line.Trim() } )
"======================================================================"

function Get-ErrHr {
    param($ex)
    try {
        $hr = [System.Runtime.InteropServices.Marshal]::GetHRForException($ex)
        return ('0x{0:X8}' -f ($hr -band 0xFFFFFFFF))
    } catch { return 'n/a' }
}

function Get-ErrText {
    param($ex)
    $parts = @()
    $cur = $ex
    while ($cur -and $parts.Count -lt 4) {
        $parts += $cur.Message
        $cur = $cur.InnerException
    }
    return ($parts -join ' | ')
}

# ---------------- value set ----------------
$vals = @([uint64]0,[uint64]1,[uint64]2,[uint64]3,[uint64]4,[uint64]5,[uint64]6,[uint64]7,
          [uint64]8,[uint64]9,[uint64]10,[uint64]16,[uint64]32,[uint64]50,[uint64]60,
          [uint64]64,[uint64]80,[uint64]90,[uint64]100,[uint64]128,[uint64]170,[uint64]187,
          [uint64]200,[uint64]255,[uint64]256,[uint64]4096,[uint64]65536,[uint64]16777216,
          [uint64]4294967295,[uint64]1515870810)   # last = 0x5A5A5A5A

$classes = @(
    @{ C='EmdAcpi_BatteryChargeRationing'; M=@('GetBatteryChargeRationing') },
    @{ C='EmdAcpi_BatteryInfo';             M=@('GetBatteryBasicInfo','GetBatteryRealtimeInfo','GetBatteryLifecapacity') },
    @{ C='EmdAcpi_ECInformation';           M=@('GetEcVersion','GetPdVersion','GetCpuTemperature') }
)
# EmdAcpi_Battery_Charge_Mode has only the switch method => intentionally NOT called.

$okCount = 0
$errCount = 0

""
"================ class-level calls ================"
foreach ($c in $classes) {
    "----- $($c.C) -----"
    foreach ($m in $c.M) {
        foreach ($v in $vals) {
            try {
                $r = Invoke-CimMethod -Namespace $ns -ClassName $c.C -MethodName $m -Arguments @{ Data = $v } -ErrorAction Stop
                $out = if ($null -ne $r.Data) { ('0x{0:X}' -f $r.Data) } else { '<null>' }
                "OK    $($c.C)#$m  Data=0x$('{0:X}' -f $v)  out=$out  rv=$($r.ReturnValue)"
                $okCount++
            } catch {
                $errCount++
                if ($errCount -le 12 -or ($v -in @([uint64]1,[uint64]80,[uint64]100,[uint64]4294967295))) {
                    "ERR   $($c.C)#$m  Data=0x$('{0:X}' -f $v)  hr=$(Get-ErrHr $_.Exception)  $((Get-ErrText $_.Exception) -replace '[^\x20-\x7E]',' ') "
                }
            }
        }
    }
}

""
"================ instance enumeration ================"
foreach ($c in $classes) {
    try {
        $insts = @(Get-CimInstance -Namespace $ns -ClassName $c.C -ErrorAction Stop)
        "  $($c.C): $($insts.Count) instance(s)"
        foreach ($inst in $insts) {
            "    InstanceName = $($inst.InstanceName)   Active=$($inst.Active)"
            foreach ($m in $c.M) {
                foreach ($v in @([uint64]0,[uint64]1,[uint64]2,[uint64]80,[uint64]100)) {
                    try {
                        $r = $inst | Invoke-CimMethod -MethodName $m -Arguments @{ Data = $v } -ErrorAction Stop
                        $out = if ($null -ne $r.Data) { ('0x{0:X}' -f $r.Data) } else { '<null>' }
                        "OK    [inst] $($c.C)#$m  Data=0x$('{0:X}' -f $v)  out=$out  rv=$($r.ReturnValue)"
                        $okCount++
                    } catch {
                        $errCount++
                        "ERR   [inst] $($c.C)#$m  Data=0x$('{0:X}' -f $v)  hr=$(Get-ErrHr $_.Exception)  $((Get-ErrText $_.Exception) -replace '[^\x20-\x7E]',' ')"
                    }
                }
            }
        }
    } catch {
        "  $($c.C): enumeration failed - hr=$(Get-ErrHr $_.Exception)  $((Get-ErrText $_.Exception) -replace '[^\x20-\x7E]',' ')"
    }
}

""
"================ result ================"
"OK=$okCount  ERR=$errCount"
if ($okCount -eq 0) {
    "No firmware GET succeeded even as administrator."
    "-> Next hypotheses: (a) EmdAcpi_* blocks are only usable by the OEM service context/driver,"
    "   (b) methods need a special Data layout, or (c) the WMI-ACPI data blocks are disabled on this BIOS."
    "-> In that case the reliable route is to mirror the OEM stack: decompile GCUService.exe"
    "   (dotnet tool install -g ilspycmd) or use the EC path the service uses."
}
try { Stop-Transcript | Out-Null } catch { }
"Log written to: $Log"
