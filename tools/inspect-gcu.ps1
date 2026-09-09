# =============================================================================
#  inspect-gcu.ps1 - reflection-only inspection of the OEM .NET service
#
#  Loads GCUService.exe (the Mechrevo/OEM control-centre service) in a
#  reflection-only context and lists types/methods/fields whose names touch
#  battery charge control. This is purely static: nothing is executed and no
#  file is modified. PowerShell 5.1 (Windows PowerShell) is required because
#  the reflection-only APIs are .NET Framework only.
#
#  Usage:
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\inspect-gcu.ps1 `
#        -Path 'C:\Program Files\OEM\机械革命控制中心\AiStoneService\MyControlCenter\GCUService.exe'
# =============================================================================
param([Parameter(Mandatory)][string]$Path)

$kw = 'Battery|Charge|Protect|Health|Ration|Acpi|ECIO|Wmi|EC|Emdoor|Uniwill'

if (-not (Test-Path $Path)) { Write-Error "file not found: $Path"; exit 1 }
$dir = Split-Path $Path -Parent

$onResolve = {
    param($sender, $args)
    try {
        $n = (New-Object System.Reflection.AssemblyName($args.Name)).Name
        foreach ($ext in @('.dll', '.exe')) {
            $cand = Join-Path $dir ($n + $ext)
            if (Test-Path $cand) { return [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($cand) }
        }
    } catch { }
    return $null
}
[System.AppDomain]::CurrentDomain.add_ReflectionOnlyAssemblyResolve($onResolve)

$asm = try { [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($Path) } catch { Write-Error "load failed: $($_.Exception.Message)"; exit 1 }
"Assembly: $($asm.FullName)"
""

$types = @()
try { $types = @($asm.GetTypes()) }
catch [System.Reflection.ReflectionTypeLoadException] {
    $types = @($_.Exception.Types | Where-Object { $_ })
    "note: some types failed to resolve ($($_.Exception.LoaderExceptions.Count) loader exceptions)"
}
catch { Write-Error "GetTypes failed: $($_.Exception.Message)"; exit 1 }

"Loaded types: $($types.Count)"

""
"===== Types whose name matches '$kw' ====="
foreach ($t in $types) {
    if ($t.Name -notmatch $kw) { continue }
    "TYPE $($t.FullName)  ($($t.Attributes))"
    foreach ($m in $t.GetMethods([System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly')) {
        "    M $($m.Name)"
    }
    foreach ($f in $t.GetFields([System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly')) {
        $lit = ''
        if ($f.IsLiteral) { $lit = ' = ' + $f.GetRawConstantValue() }
        "    F $($f.Name) : $($f.FieldType.Name)$lit"
    }
}

""
"===== Any method/property across ALL types matching '$kw' ====="
$hits = @()
foreach ($t in $types) {
    foreach ($m in $t.GetMethods([System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly')) {
        if ($m.Name -match $kw) { $hits += "$($t.FullName)::$($m.Name)" }
    }
    foreach ($p in $t.GetProperties([System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly')) {
        if ($p.Name -match $kw) { $hits += "$($t.FullName)::[prop]$($p.Name)" }
    }
}
$hits | Sort-Object -Unique | Select-Object -First 120 | ForEach-Object { "    $_" }
""
"Done."
