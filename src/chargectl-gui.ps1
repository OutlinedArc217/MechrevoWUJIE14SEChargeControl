# =============================================================================
#  chargectl-gui.ps1 - small WinForms front end (run elevated)
#      powershell -ExecutionPolicy Bypass -File .\chargectl-gui.ps1
# =============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = Split-Path $MyInvocation.MyCommand.Path -Parent
Import-Module (Join-Path $here 'MechrevoChargeControl.psm1') -Force

$f = New-Object System.Windows.Forms.Form
$f.Text = 'Mechrevo Charge Control (Uniwill/Emdoor ACPI-WMI)'
$f.Size = New-Object System.Drawing.Size(620, 460)
$f.StartPosition = 'CenterScreen'

$txt = New-Object System.Windows.Forms.TextBox
$txt.Multiline = $true
$txt.ScrollBars = 'Vertical'
$txt.ReadOnly = $true
$txt.Dock = 'Fill'
$txt.Font = New-Object System.Drawing.Font('Consolas', 9)

$pnl = New-Object System.Windows.Forms.Panel
$pnl.Dock = 'Bottom'
$pnl.Height = 90

function Add-Btn($text, $scriptBlock, $x, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 8)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.Add_Click($scriptBlock)
    $pnl.Controls.Add($b)
    return $b
}

function Write-Out($s) { $txt.AppendText("$s`r`n") }

Add-Btn 'Query status' {
    try {
        $s = Get-ChargeControlStatus
        Write-Out ('Elevated: ' + $s.Admin)
        Write-Out ('OEM registry: HealthProtectionStatus=' + $s.OEM.HealthProtectionStatus +
                   '  TypeCAdaptorPriority=' + $s.OEM.TypeCAdaptorPriorityStatus)
        $b = $s.Battery
        Write-Out ('Battery: OS%=' + $b.OSPercent + ' charging=' + $b.Charging +
                   ' rate(mW)=' + $b.ChargeRate_mW + ' full(mWh)=' + $b.FullChargedCapacity_mWh)
        if ($s.FirmwareReadsOk.Count) { Write-Out ('Firmware reads OK: ' + ($s.FirmwareReadsOk | ConvertTo-Json -Compress)) }
        else { Write-Out 'Firmware reads: none (run elevated; if still none the Data word is unknown - see FORENSICS.md)' }
    } catch { Write-Out ('ERR: ' + $_.Exception.Message) }
} 10 150

$n = 0
foreach ($p in @(@('Full 100%',100),@('Balanced ~80%',80),@('Stationary ~60%',60))) {
    $n++
    $percent = $p[1]
    Add-Btn ($p[0]) {
        param($sender, $e)
        $pct = $percent
        if (-not (Test-IsAdministrator)) { Write-Out 'ERR: not elevated - relaunch as administrator'; return }
        if ([System.Windows.Forms.MessageBox]::Show(
                "Set charge rationing Data=$pct via SetBatteryChargeRationing?`n(experimental encoding - verify afterwards)",
                'Confirm', 'YesNo', 'Warning') -ne 'Yes') { return }
        try {
            $r = Set-EmdChargeRationing -Data ([uint64]$pct) -Force
            Write-Out ('Set result: OK=' + $r.Ok + ' out=' + $r.DataOut + ' err=' + $r.Error)
            Write-Out 'Now watch: does charging stop at the target %?'
        } catch { Write-Out ('ERR: ' + $_.Exception.Message) }
    } (10 + $n * 155) 145
}

$f.Controls.Add($txt)
$f.Controls.Add($pnl)
$f.Add_Shown({ Write-Out 'MechrevoChargeControl GUI. All writes are experimental; verify after each change.' })
[void]$f.ShowDialog()
