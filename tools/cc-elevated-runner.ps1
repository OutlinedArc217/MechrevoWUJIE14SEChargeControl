# =============================================================================
#  cc-elevated-runner.ps1 - internal helper (launched elevated)
#  Runs chargectl.ps1 with parsed arguments and transcripts the output.
#  CmdTokens is a single comma-separated token string; tokens are parsed into
#  a positional command + named parameters (supports "-Name value" and bare
#  switches like "-Force").
# =============================================================================
param(
    [string]$Cli,
    [string]$CmdTokens,
    [string]$LogFile
)
$ErrorActionPreference = 'Continue'

$tokens = @($CmdTokens -split ',')
$pos = @()
$named = @{}
for ($i = 0; $i -lt $tokens.Count; $i++) {
    $t = $tokens[$i]
    if ($t -match '^-') {
        $n = $t.TrimStart('-')
        if ($i + 1 -lt $tokens.Count -and $tokens[$i + 1] -notmatch '^-') {
            $named[$n] = $tokens[$i + 1]
            $i++
        } else {
            $named[$n] = $true
        }
    } else {
        $pos += $t
    }
}

try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { }
"RUN: & '$Cli' $($CmdTokens -replace ',', ' ')"
try {
    if ($named.Count -gt 0) {
        if ($pos.Count -gt 0) { & $Cli $pos[0] @named } else { & $Cli @named }
    } else {
        & $Cli @pos
    }
} catch {
    "ERROR: $($_.Exception.Message)"
}
try { Stop-Transcript | Out-Null } catch { }
