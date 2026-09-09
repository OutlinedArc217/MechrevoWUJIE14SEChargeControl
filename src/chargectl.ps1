# =============================================================================
#  chargectl.ps1 - CLI for MechrevoChargeControl
#
#  Usage (from an elevated PowerShell 5.1/7 console):
#    .\chargectl.ps1 status                       read current state
#    .\chargectl.ps1 info                         show firmware WMI classes/GUIDs
#    .\chargectl.ps1 watch [-Seconds 120]         poll charging behaviour
#    .\chargectl.ps1 set-limit -Percent 80        rationing (SetBatteryChargeRationing)
#    .\chargectl.ps1 set-mode -Profile Stationary mode channel (Battery_Charge_Mode)
#    .\chargectl.ps1 oemreg -Status 1            persist OEM registry flag only
#    .\chargectl.ps1 rawset -Class ChargeRationing -Method Set -Data 80
#
#  IMPORTANT: the EmdAcpi_* methods are invoked through their WMI instance
#  (ACPI\PNP0C14\HWMI_0) and instance enumeration needs elevation - run this
#  from an elevated console, or use tools\SetChargeCap-Elevated.ps1 /
#  tools\RunProbe2Elevated.ps1 which raise UAC for you.
#
#  All write commands require explicit -Force (or ShouldProcess confirmation).
#  Semantics of the Data word: verified to be reachable through the instance;
#  exact encoding was confirmed with the calibration in probe2-elevated.ps1.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command = 'status',
    [ValidateRange(0,100)][int]$Percent,
    [ValidateSet('Full','Balanced','Stationary')][string]$Profile,
    [ValidateSet('ChargeMode','ChargeRationing')][string]$Class,
    [ValidateSet('Set','Mode','Get')][string]$Method,
    [uint64]$Data,
    [int]$Status,
    [int]$Seconds = 120,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
Import-Module (Join-Path $here 'MechrevoChargeControl.psm1') -Force

function Show-Status {
    $s = Get-ChargeControlStatus
    '=== Machine ==='
    $cs = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
    "Manufacturer: $($cs.Manufacturer)  Model: $($cs.Model)"
    "Elevated: $($s.Admin)"
    '=== Battery (Windows telemetry) ==='
    $s.Battery | Format-List | Out-String | Write-Host
    '=== OEM registry (what the OEM control centre persists) ==='
    $s.OEM | Format-List | Out-String | Write-Host
    if ($s.RegistryGuess) { "Guess: $($s.RegistryGuess)" }
    '=== Firmware reads (instance ACPI\PNP0C14\HWMI_0; empty = run elevated) ==='
    if ($s.FirmwareReads.Count -eq 0) { '  (none - run this from an elevated console)' }
    else {
        $s.FirmwareReads | ForEach-Object {
            if ($_.Ok) { "  OK    $($_.Class)#$($_.Method)  out=0x$($_.DataOutHex)" }
            else { "  ERROR $($_.Class)#$($_.Method)  $($_.Error)" }
        }
    }
}

switch ($Command) {
    'info' {
        'Firmware ACPI-WMI classes (root\WMI) exposed by ACPI\PNP0C14\HWMI:'
        foreach ($c in @('EmdAcpi_Battery_Charge_Mode','EmdAcpi_BatteryChargeRationing','EmdAcpi_BatteryInfo','EmdAcpi_ECInformation')) {
            Get-EmdSchema -ClassName $c | Format-List | Out-String | Write-Host
        }
    }
    'status'  { Show-Status }
    'probe'   {
        'Run the elevated probe from a NORMAL console:'
        '  powershell -ExecutionPolicy Bypass -File .\tools\RunProbe2Elevated.ps1'
        '  powershell -ExecutionPolicy Bypass -File .\tools\RunProbe2Elevated.ps1 -AllowCalibration   # + neutral calibration write'
    }
    'watch'   { Watch-ChargingBehavior -Seconds $Seconds }
    'set-limit' {
        if ($null -eq $Percent) { throw 'set-limit requires -Percent (0..100; 0 = limit inactive).' }
        if (-not $Force) { throw 'add -Force after reviewing what this command does.' }
        $r = Set-EmdChargeRationing -Data ([uint64]$Percent) -Force
        if ($r.Ok) { "SET ok (out=$($r.DataOut)). Verify with status/watch." } else { "SET failed: $($r.Error)" }
    }
    'set-mode' {
        if (-not $Profile) { throw 'set-mode requires -Profile Full|Balanced|Stationary.' }
        if (-not $Force) { throw 'add -Force after reviewing what this command does.' }
        $word = switch ($Profile) { 'Full' { 0 } 'Balanced' { 1 } 'Stationary' { 2 } }
        $r = Set-EmdChargeMode -Data ([uint64]$word) -Force
        if ($r.Ok) { "SET ok (out=$($r.DataOut)). Verify with status/watch." } else { "SET failed: $($r.Error)" }
    }
    'oemreg' {
        if ($null -eq $Status) { throw 'oemreg requires -Status 0..2.' }
        Set-OemProtectionRegistry -Status $Status -Force
        'Registry updated (flag only - firmware behaviour unchanged by itself).'
    }
    'rawset' {
        if ($null -eq $Data) { throw 'rawset requires -Data.' }
        if (-not $Force) { throw 'add -Force after reviewing what this command does.' }
        $cls = switch ($Class) { 'ChargeMode' { 'EmdAcpi_Battery_Charge_Mode' } 'ChargeRationing' { 'EmdAcpi_BatteryChargeRationing' } }
        $mth = switch ($Method) { 'Mode' { 'Battery_Charge_Mode' } 'Set' { 'SetBatteryChargeRationing' } 'Get' { 'GetBatteryChargeRationing' } }
        Invoke-EmdMethod -ClassName $cls -MethodName $mth -Data $Data | Format-List | Out-String | Write-Host
    }
    default { throw "unknown command '$Command'" }
}
