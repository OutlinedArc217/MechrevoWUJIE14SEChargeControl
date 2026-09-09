# =============================================================================
#  MechrevoChargeControl.psm1
#
#  A small, read-mostly toolbox for the battery charge control interface that
#  the firmware of Uniwill/Emdoor-based MECHREVO (and similar) notebooks
#  exposes through ACPI-WMI (device ACPI\PNP0C14\HWMI, classes EmdAcpi_*).
#
#  IMPORTANT discovery (verified 2026 on a WUJIE14SE):
#    The EmdAcpi_* methods ONLY accept calls through their WMI instance
#    (InstanceName = ACPI\PNP0C14\HWMI_0). Class-level Invoke-CimMethod fails
#    with "invalid method parameter"; instance-level calls succeed. Instance
#    enumeration itself requires an elevated process.
#
#  Everything here is either read-only or guarded behind explicit switches.
#  Written for Windows PowerShell 5.1+ / PowerShell 7, ASCII only on purpose.
# =============================================================================

Set-StrictMode -Version 2

# ---------- constants -------------------------------------------------------
$script:WmiNamespace = 'root\WMI'
$script:ChargeModeClass      = 'EmdAcpi_Battery_Charge_Mode'
$script:ChargeRationingClass = 'EmdAcpi_BatteryChargeRationing'
$script:BatteryInfoClass     = 'EmdAcpi_BatteryInfo'
$script:ECInfoClass          = 'EmdAcpi_ECInformation'

$script:OemRegKey = 'HKLM:\SOFTWARE\OEM\GamingCenter2\BatteryProtection2'
$script:OemStatusValue   = 'HealthProtectionStatus'
$script:OemTypecPriority = 'TypeCAdaptorPriorityStatus'

$script:LogDir = Join-Path $env:ProgramData 'MechrevoChargeControl\logs'

# ---------- helpers ---------------------------------------------------------

function Test-IsAdministrator {
    <#
    .SYNOPSIS
      Returns $true when the current process runs elevated.
    #>
    try {
        $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr  = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path (Join-Path $script:LogDir 'chargectrl.log') -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# ---------- low-level WMI calls (INSTANCE based!) ---------------------------

function Get-EmdInstance {
    <#
    .SYNOPSIS
      Enumerates the first instance of an EmdAcpi_* class (requires admin).
      Returns a CIM instance that can be piped into Invoke-CimMethod.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClassName)
    try {
        $i = Get-CimInstance -Namespace $script:WmiNamespace -ClassName $ClassName -ErrorAction Stop | Select-Object -First 1
        return $i
    } catch {
        return $null
    }
}

function Invoke-EmdMethod {
    <#
    .SYNOPSIS
      Invokes one of the EmdAcpi_* ACPI-WMI methods with a UInt64 Data word,
      ALWAYS through a WMI instance (class-level calls are rejected by the
      firmware). Requires an elevated process for the enumeration step.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('EmdAcpi_Battery_Charge_Mode','EmdAcpi_BatteryChargeRationing','EmdAcpi_BatteryInfo','EmdAcpi_ECInformation')]
        [string]$ClassName,
        [Parameter(Mandatory)][string]$MethodName,
        [Parameter(Mandatory)][uint64]$Data,
        [int]$TimeoutSec = 20
    )
    Write-Log "Invoke-EmdMethod $ClassName::$MethodName Data=0x$('{0:X}' -f $Data)"
    $inst = Get-EmdInstance -ClassName $ClassName
    if (-not $inst) {
        return [pscustomobject]@{
            Ok = $false; Class = $ClassName; Method = $MethodName
            DataIn = $Data; DataOut = $null; ReturnValue = $null
            Error = 'No WMI instance visible - run elevated (instance enumeration of EmdAcpi_* requires admin).'
        }
    }
    try {
        $r = $inst | Invoke-CimMethod -MethodName $MethodName -Arguments @{ Data = $Data } -ErrorAction Stop
        $out = $null
        if ($null -ne $r -and $null -ne $r.Data) { $out = $r.Data }
        return [pscustomobject]@{
            Ok = $true; Class = $ClassName; Method = $MethodName
            DataIn = $Data
            DataOut = $out
            ReturnValue = $(if ($null -ne $r.ReturnValue) { $r.ReturnValue } else { $null })
            Error = $null
        }
    } catch {
        $msg = $_.Exception.Message
        Write-Log "Invoke-EmdMethod FAILED: $msg"
        return [pscustomobject]@{
            Ok = $false; Class = $ClassName; Method = $MethodName
            DataIn = $Data; DataOut = $null; ReturnValue = $null; Error = $msg
        }
    }
}

function Get-EmdSchema {
    <#
    .SYNOPSIS
      Prints the class schema (methods/params/qualifiers incl. WMI GUID).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClassName)
    $cl = Get-CimClass -Namespace $script:WmiNamespace -ClassName $ClassName -ErrorAction SilentlyContinue
    if (-not $cl) { Write-Warning "class $ClassName not found in $script:WmiNamespace"; return }
    $guid = ($cl.CimClassQualifiers | Where-Object { $_.Name -eq 'guid' } | Select-Object -First 1).Value
    [pscustomobject]@{ ClassName=$cl.CimClassName; Guid=$guid }
    foreach ($m in $cl.CimClassMethods) {
        [pscustomobject]@{ 'Method' = $m.Name; 'Params' = (($m.Parameters | ForEach-Object { "$($_.Name):$($_.CimType)$(if($_.IsArray){'[]'})" }) -join ', ') }
    }
}

# ---------- battery state (Windows side, read-only) -------------------------

function Get-BatteryLive {
    <#
    .SYNOPSIS
      Reads standard ACPI battery telemetry (charge %, charging flag, rates).
    #>
    $out = [ordered]@{ }
    try {
        $b = Get-CimInstance -Namespace root\WMI -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
        if ($b) {
            $out.RemainingCapacity_mWh = $b.RemainingCapacity
            $out.Charging = [bool]$b.Charging
            $out.Discharging = [bool]$b.Discharging
            $out.ChargeRate_mW = $b.ChargeRate
            $out.DischargeRate_mW = $b.DischargeRate
            $out.PowerOnline = [bool]$b.PowerOnline
        }
    } catch { $out.WmiBatteryError = $_.Exception.Message }
    try {
        $fc = Get-CimInstance -Namespace root\WMI -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
        if ($fc) { $out.FullChargedCapacity_mWh = $fc.FullChargedCapacity }
    } catch { }
    try {
        $w = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($w) { $out.OSPercent = $w.EstimatedChargeRemaining }
    } catch { }
    return [pscustomobject]$out
}

function Get-OemRegistryState {
    <#
    .SYNOPSIS
      Reads what the OEM control centre persisted for battery health protection.
    #>
    try {
        $p = Get-ItemProperty -Path $script:OemRegKey -ErrorAction Stop
        return [pscustomobject]@{
            KeyExists = $true
            HealthProtectionStatus = $(if ($null -ne $p.$($script:OemStatusValue)) { $p.$($script:OemStatusValue) } else { $null })
            TypeCAdaptorPriorityStatus = $(if ($null -ne $p.$($script:OemTypecPriority)) { $p.$($script:OemTypecPriority) } else { $null })
        }
    } catch {
        return [pscustomobject]@{ KeyExists=$false; HealthProtectionStatus=$null; TypeCAdaptorPriorityStatus=$null }
    }
}

# ---------- high level read / status ---------------------------------------

function Get-ChargeControlStatus {
    <#
    .SYNOPSIS
      Combines everything we can observe (battery telemetry + OEM registry +
      firmware reads through the WMI instance) into one report object.
    #>
    $oem = Get-OemRegistryState
    $batt = Get-BatteryLive
    $admin = Test-IsAdministrator

    $fw = @()
    if ($admin) {
        # single reads (Data word is a fixed 8-byte buffer; value 0 is fine)
        foreach ($try in @(
                @{ C='EmdAcpi_BatteryChargeRationing'; M='GetBatteryChargeRationing' },
                @{ C='EmdAcpi_BatteryInfo';             M='GetBatteryBasicInfo' },
                @{ C='EmdAcpi_BatteryInfo';             M='GetBatteryRealtimeInfo' },
                @{ C='EmdAcpi_BatteryInfo';             M='GetBatteryLifecapacity' },
                @{ C='EmdAcpi_ECInformation';           M='GetEcVersion' },
                @{ C='EmdAcpi_ECInformation';           M='GetPdVersion' },
                @{ C='EmdAcpi_ECInformation';           M='GetCpuTemperature' })) {
            $r = Invoke-EmdMethod -ClassName $try.C -MethodName $try.M -Data ([uint64]0)
            $fw += [pscustomobject]@{
                Class=$try.C; Method=$try.M
                Ok=$r.Ok
                DataOutHex=$(if($r.Ok -and $null -ne $r.DataOut){'0x{0:X}' -f $r.DataOut}else{''})
                Error=$r.Error
            }
        }
    }

    $guess = $null
    if ($null -ne $oem.HealthProtectionStatus) {
        # official enum (from static analysis of OEM GCUService.exe):
        # 0 = PERFORMANCE/Long-life(full), 1 = BALANCED, 2 = HEALTHY/Workstation
        $guess = switch ($oem.HealthProtectionStatus) {
            0 { 'OEM HealthProtectionStatus = 0  => PERFORMANCE / Long-life (charge to full)' }
            1 { 'OEM HealthProtectionStatus = 1  => BALANCED (protection profile active)' }
            2 { 'OEM HealthProtectionStatus = 2  => HEALTHY / Workstation (lowest cap)' }
            default { "OEM registry HealthProtectionStatus = $($oem.HealthProtectionStatus) (unknown)" }
        }
    }

    return [pscustomobject]@{
        Admin = $admin
        OEM   = $oem
        Battery = $batt
        FirmwareReads = @($fw)
        RegistryGuess = $guess
    }
}

# ---------- write operations (guarded) --------------------------------------

function Set-EmdChargeMode {
    <#
    .SYNOPSIS
      Calls EmdAcpi_Battery_Charge_Mode::Battery_Charge_Mode(Data) via instance.
    .EXAMPLE
      Set-EmdChargeMode -Data 2 -Force          # hypothesis H1: mode 2 = stationary
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][uint64]$Data,
        [switch]$Force
    )
    if (-not (Test-IsAdministrator)) { throw 'Elevation required: re-run from an elevated PowerShell.' }
    $what = "Battery_Charge_Mode Data=0x$('{0:X}' -f $Data)"
    if ($Force -or $PSCmdlet.ShouldProcess('firmware (EmdAcpi_Battery_Charge_Mode)', $what)) {
        return Invoke-EmdMethod -ClassName $script:ChargeModeClass -MethodName 'Battery_Charge_Mode' -Data $Data
    }
}

function Set-EmdChargeRationing {
    <#
    .SYNOPSIS
      Calls EmdAcpi_BatteryChargeRationing::SetBatteryChargeRationing(Data) via instance.
    .EXAMPLE
      Set-EmdChargeRationing -Data 80 -Force      # hypothesis: Data word == charge cap %
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][uint64]$Data,
        [switch]$Force
    )
    if (-not (Test-IsAdministrator)) { throw 'Elevation required: re-run from an elevated PowerShell.' }
    $what = "SetBatteryChargeRationing Data=0x$('{0:X}' -f $Data)"
    if ($Force -or $PSCmdlet.ShouldProcess('firmware (EmdAcpi_BatteryChargeRationing)', $what)) {
        return Invoke-EmdMethod -ClassName $script:ChargeRationingClass -MethodName 'SetBatteryChargeRationing' -Data $Data
    }
}

function Set-OemProtectionRegistry {
    <#
    .SYNOPSIS
      Persists the same key the OEM control centre uses so the two stay in sync.
      This only stores a flag; it does not by itself change firmware behaviour.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(0,2)][int]$Status,
        [switch]$Force
    )
    if (-not (Test-IsAdministrator)) { throw 'Elevation required.' }
    $what = "set $script:OemRegKey\$script:OemStatusValue = $Status"
    if ($Force -or $PSCmdlet.ShouldProcess('registry', $what)) {
        if (-not (Test-Path $script:OemRegKey)) {
            New-Item -Path $script:OemRegKey -Force | Out-Null
        }
        Set-ItemProperty -Path $script:OemRegKey -Name $script:OemStatusValue -Value $Status -Type DWord
        Write-Log "registry $script:OemStatusValue = $Status"
    }
}

# ---------- watch -----------------------------------------------------------

function Watch-ChargingBehavior {
    <#
    .SYNOPSIS
      Polls charging state. Useful to verify that a cap/profile really stops
      charging at the target level (note: some ECs hide charging status when a
      charge profile is active; watch ChargeRate too).
    #>
    param([int]$Seconds = 120, [int]$Interval = 5)
    $until = (Get-Date).AddSeconds($Seconds)
    do {
        $b = Get-BatteryLive
        '{0}  pct~{1,-4} charging={2,-5} rate={3,7} mW  full={4} mWh' -f `
            (Get-Date -Format 'HH:mm:ss'), $b.OSPercent, $b.Charging, $b.ChargeRate_mW, $b.FullChargedCapacity_mWh
        Start-Sleep -Seconds $Interval
    } while ((Get-Date) -lt $until)
}

Export-ModuleMember -Function @(
    'Test-IsAdministrator','Get-EmdInstance','Invoke-EmdMethod','Get-EmdSchema',
    'Get-BatteryLive','Get-OemRegistryState','Get-ChargeControlStatus',
    'Set-EmdChargeMode','Set-EmdChargeRationing','Set-OemProtectionRegistry',
    'Watch-ChargingBehavior'
)
