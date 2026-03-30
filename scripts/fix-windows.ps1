# GeoShift Windows fix script - run once as Administrator on any existing installation.
# Applies three fixes:
#   1. SSH key file owner -> NT AUTHORITY\SYSTEM  (fixes "Permission denied (publickey)")
#   2. Scheduled tasks allowed to start on battery  (fixes task not auto-starting on boot)
#   3. Startup delays: 30 s (tunnel) / 40 s (mihomo)  (lets NIC get IP before ssh connects)
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\fix-windows.ps1

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

$EnvFile = 'C:\ProgramData\GeoShift\geoshift.env'

function info  { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function ok    { param([string]$m) Write-Host "  OK  $m" -ForegroundColor Green }
function warn  { param([string]$m) Write-Host "  WARN $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Fix 1: SSH key owner
# ---------------------------------------------------------------------------
info "Fix 1: SSH key file owner -> NT AUTHORITY\SYSTEM"

$keyPath = $null
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        $line = $line.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { continue }
        if ($line -match '^SSH_PRIVATE_KEY\s*=\s*(.+)$') {
            $candidate = $Matches[1].Trim().Trim('"')
            if ($candidate -notmatch 'your\.|placeholder|^/' -and $candidate -match '^[A-Za-z]:\\') {
                $keyPath = $candidate
            }
            break
        }
    }
}

if (-not $keyPath) {
    warn "SSH_PRIVATE_KEY not set to a Windows path in $EnvFile - skipping key fix."
    warn "Set SSH_PRIVATE_KEY and re-run this script."
} elseif (-not (Test-Path $keyPath)) {
    warn "Key file not found: $keyPath - skipping."
} else {
    try {
        $acl = Get-Acl $keyPath

        # Change owner to SYSTEM
        $systemSid     = [System.Security.Principal.SecurityIdentifier]'S-1-5-18'
        $systemAccount = $systemSid.Translate([System.Security.Principal.NTAccount])
        $acl.SetOwner($systemAccount)

        # Strip all inherited ACEs, clear explicit ACEs
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { $acl.RemoveAccessRule($r) | Out-Null }

        # Grant SYSTEM Read only
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $systemSid, 'Read', 'None', 'None', 'Allow')
        $acl.AddAccessRule($rule)

        Set-Acl $keyPath $acl
        ok "Owner=SYSTEM, ACL=SYSTEM:Read  ($keyPath)"
    } catch {
        warn "Could not fix key permissions: $_"
    }
}

# ---------------------------------------------------------------------------
# Fix 2 + 3: Task battery settings and startup delays
# ---------------------------------------------------------------------------
info "Fix 2+3: Scheduled task battery flags and startup delays"

$tasks = @(
    @{ Name = 'GeoShift-Tunnel-US'; Delay = 'PT30S' }
    @{ Name = 'GeoShift-Mihomo';    Delay = 'PT40S' }
)

foreach ($entry in $tasks) {
    $t = Get-ScheduledTask -TaskName $entry.Name -ErrorAction SilentlyContinue
    if (-not $t) {
        warn ($entry.Name + ' task not found - skipping.')
        continue
    }

    $t.Settings.DisallowStartIfOnBatteries = $false
    $t.Settings.StopIfGoingOnBatteries      = $false

    if ($t.Triggers.Count -gt 0) {
        $t.Triggers[0].Delay = $entry.Delay
    }

    Set-ScheduledTask -InputObject $t | Out-Null
    ok ($entry.Name + ': battery=allow, delay=' + $entry.Delay)
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'All fixes applied.' -ForegroundColor Green
Write-Host 'Restart the tasks to pick up the changes:'
Write-Host '  Stop-ScheduledTask  -TaskName GeoShift-Tunnel-US'
Write-Host '  Stop-ScheduledTask  -TaskName GeoShift-Mihomo'
Write-Host '  Start-ScheduledTask -TaskName GeoShift-Tunnel-US'
Write-Host '  Start-ScheduledTask -TaskName GeoShift-Mihomo'
Write-Host ''
Write-Host 'Or simply reboot - tasks will start 30/40 s after Windows boots.'
