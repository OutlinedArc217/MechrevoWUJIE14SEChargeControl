# =============================================================================
#  probe-interface.ps1  - READ-ONLY probe of the firmware charge interface
#
#  Runs a matrix of safe "Get*" method calls against the EmdAcpi_* classes and
#  reports which Data words the firmware accepts and what it returns. Nothing
#  is modified. Run it elevated:
#      powershell -ExecutionPolicy Bypass -File .\probe-interface.ps1
#  Results are printed and written to config\lastProbe.json for later use.
# =============================================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
Import-Module (Join-Path $here 'MechrevoChargeControl.psm1') -Force

$admin = Test-IsAdministrator
"Elevated: $admin   (probe is most informative when run elevated)"
""

# matrix: class -> list of (method, [data words])
$matrix = [ordered]@{
    'EmdAcpi_BatteryChargeRationing' = @(
        @('GetBatteryChargeRationing', @(0,1,2,3,4,5,6,7,8,9,10,16,20,32,40,60,64,80,90,100,128,255,256,0x1000,0x10000,0x01000000,4294967295))
    )
    'EmdAcpi_Battery_Charge_Mode'    = @()   # NOT probed: it is a switch, not a getter
    'EmdAcpi_BatteryInfo'            = @(
        @('GetBatteryBasicInfo',    @(0,1,2,3,4,8,16,0x10,0x20,0x100,0x1000,0x1234,4294967295)),
        @('GetBatteryRealtimeInfo', @(0,1,2,3,4,8,16,0x10,0x20,0x100,0x1000,0x1234,4294967295)),
        @('GetBatteryLifecapacity', @(0,1,2,3,4,8,16,0x10,0x20,0x100,0x1000,0x1234,4294967295))
    )
    'EmdAcpi_ECInformation'          = @(
        @('GetEcVersion',     @(0,1,2,3,4,5,6,7,8,0x10,0x100,0x1000,4294967295)),
        @('GetPdVersion',     @(0,1,2,3,4,5,6,7,8,0x10,0x100,0x1000,4294967295)),
        @('GetCpuTemperature',@(0,1,2,3,4,5,6,7,8,0x10,0x100,0x1000,4294967295))
    )
}

$results = @()
foreach ($cls in $matrix.Keys) {
    "===== $cls ====="
    foreach ($entry in $matrix[$cls]) {
        $mth = $entry[0]
        foreach ($w in $entry[1]) {
            $r = Invoke-EmdMethod -ClassName $cls -MethodName $mth -Data ([uint64]$w)
            $status = if ($r.Ok) { 'OK ' } else { 'ERR' }
            $detail = if ($r.Ok) {
                "out=0x$(if($null -ne $r.DataOut){'{0:X}' -f $r.DataOut}else{'?'}) rv=$($r.ReturnValue)"
            } else {
                "($($r.Error))"
            }
            $results += [pscustomobject]@{
                Class=$cls; Method=$mth; DataIn=('0x{0:X}' -f $w); Ok=$r.Ok; Detail=$detail
            }
            if ($r.Ok) { "  OK  $mth  Data=0x$('{0:X}' -f $w)  $detail" }
        }
    }
}

# summary
""
$okN = @($results | Where-Object { $_.Ok }).Count
"Probe summary: $okN succeeded out of $($results.Count) calls."
$errBins = $results | Where-Object { -not $_.Ok } | Group-Object Detail | Sort-Object Count -Descending | Select-Object -First 6
foreach ($b in $errBins) { "  error '$(($b.Name -replace '[^\x20-\x7E]',' '))' x $($b.Count)" }
if ($okN -eq 0) {
    ""
    "No firmware GET succeeded from this context."
    "If this run was NOT elevated: re-run as administrator."
    "If elevated and still zero: the firmware likely needs a specific Data word or an instance context;"
    "try small values like 1..8 and inspect any 'reject' diagnostics above; report back to the developer."
}

# also try instance-level invocation (some firmwares only answer on an instance)
""
"===== instance enumeration / instance-level call attempt ====="
foreach ($cls in @('EmdAcpi_BatteryChargeRationing','EmdAcpi_BatteryInfo','EmdAcpi_ECInformation')) {
    $insts = Get-EmdInstances -ClassName $cls
    if ($insts.Count -eq 0) { "  $cls : no instance visible (access denied or method-only class)" }
    else {
        foreach ($inst in $insts) {
            "  $cls instance: $($inst.InstanceName)"
            foreach ($m in @('GetBatteryChargeRationing','GetBatteryBasicInfo','GetEcVersion')) {
                try {
                    $r2 = $inst | Invoke-CimMethod -MethodName $m -Arguments @{ Data = [uint64]0 } -ErrorAction Stop
                    "     $m on instance -> $($r2 | ConvertTo-Json -Compress)"
                } catch { "     $m on instance -> ERR $($_.Exception.Message)" }
            }
        }
    }
}

# persist
try {
    $outFile = Join-Path (Split-Path $here -Parent) 'config\lastProbe.json'
    $results | ConvertTo-Json -Depth 4 | Set-Content -Path $outFile -Encoding UTF8
    ""
    "Saved report: $outFile"
} catch { Write-Warning "could not save report: $($_.Exception.Message)" }
