# GeoShift post-install checks (matches ARCHITECTURE.md Verification section)
# Run: powershell -ExecutionPolicy Bypass -File scripts\verify-geoshift.ps1

$ErrorActionPreference = 'Continue'

Write-Host '=== Step 1: Installer paths and files ===' -ForegroundColor Cyan
$paths = @(
    'C:\Program Files\GeoShift',
    'C:\ProgramData\GeoShift',
    'C:\ProgramData\GeoShift\logs'
)
foreach ($p in $paths) {
    Write-Host ("  {0} -> {1}" -f $p, (Test-Path $p))
}
Write-Host '  Files under Program Files\GeoShift:'
if (Test-Path 'C:\Program Files\GeoShift') {
    Get-ChildItem 'C:\Program Files\GeoShift' | Select-Object -ExpandProperty Name
} else {
    Write-Host '  (missing)'
}

Write-Host ''
Write-Host '=== Step 2: Config (sanitized) ===' -ForegroundColor Cyan
$envf = 'C:\ProgramData\GeoShift\geoshift.env'
if (-not (Test-Path $envf)) {
    Write-Host '  MISSING geoshift.env'
} else {
    Get-Content $envf | ForEach-Object {
        $line = $_
        if ($line -match '^\s*#' -or $line -match '^\s*$') {
            Write-Host "  $line"
            return
        }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            if ($k -eq 'SSH_PRIVATE_KEY') {
                $show = if ($v -match 'placeholder|your\.|CHANGE|lightsail\.pem$' -and $v -notmatch '^C:\\') { $v } elseif (Test-Path $v) { '(path exists)' } else { '(path not found on disk)' }
            }
            elseif ($k -eq 'US_LIGHTSAIL_IP') {
                $show = if ($v -match 'your\.|placeholder') { $v } else { '(set)' }
            }
            else { $show = $v }
            Write-Host ("  {0}={1}" -f $k, $show)
        }
        else { Write-Host "  $line" }
    }
    Write-Host '  YAML in config:'
    if (Test-Path 'C:\ProgramData\GeoShift\config') {
        Get-ChildItem 'C:\ProgramData\GeoShift\config' -Filter '*.yaml' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name
    } else { Write-Host '  (config dir missing)' }
}

Write-Host ''
Write-Host '=== Step 3: Scheduled tasks ===' -ForegroundColor Cyan
$tasks = Get-ScheduledTask -TaskName 'GeoShift-*' -ErrorAction SilentlyContinue
if (-not $tasks) {
    Write-Host '  No GeoShift-* tasks found.'
} else {
    $tasks | Select-Object TaskName, State | Format-Table -AutoSize
    foreach ($t in @('GeoShift-Tunnel-US', 'GeoShift-Mihomo')) {
        $st = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if (-not $st) { Write-Host "  $t : not registered"; continue }
        $i = $st | Get-ScheduledTaskInfo
        Write-Host ("  {0}: LastTaskResult={1} LastRunTime={2} NextRunTime={3}" -f $t, $i.LastTaskResult, $i.LastRunTime, $i.NextRunTime)
    }
}

Write-Host ''
Write-Host '=== Step 4: SSH key ACL (from env path) ===' -ForegroundColor Cyan
$keyPath = $null
if ((Test-Path $envf)) {
    Get-Content $envf | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        if ($line -match '^\s*SSH_PRIVATE_KEY\s*=\s*(.+)\s*$') {
            $keyPath = $Matches[1].Trim().Trim('"')
        }
    }
    if ($keyPath) {
        if (Test-Path $keyPath) {
            Write-Host ("  Key file exists: {0}" -f $keyPath)
            icacls $keyPath 2>&1 | ForEach-Object { Write-Host "  $_" }
        } else {
            Write-Host "  Key path from env not found: $keyPath"
        }
    } else { Write-Host '  No active SSH_PRIVATE_KEY= line in env (uncomment and set one path)' }
} else { Write-Host '  Skip (no env file)' }

Write-Host ''
Write-Host '=== Step 5: Processes (ssh / mihomo) ===' -ForegroundColor Cyan
$procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(ssh|mihomo|plink)$' }
if ($procs) { $procs | Select-Object Name, Id | Format-Table -AutoSize }
else { Write-Host '  (none - run: Start-ScheduledTask GeoShift-Tunnel-US then GeoShift-Mihomo)' }

Write-Host ''
Write-Host '=== Step 7: Log tails ===' -ForegroundColor Cyan
foreach ($log in @('tunnel-us.log', 'mihomo.log', 'mihomo-core.log')) {
    $lp = Join-Path 'C:\ProgramData\GeoShift\logs' $log
    Write-Host "--- $log ---"
    if (Test-Path $lp) { Get-Content $lp -Tail 15 }
    else { Write-Host '  (file missing)' }
}

Write-Host ''
Write-Host '=== Step 6 / 8: Quick network hints ===' -ForegroundColor Cyan
$listen9090 = Get-NetTCPConnection -LocalPort 9090 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ("  Port 9090 listen: {0}" -f ([bool]$listen9090))
$listen1080 = Get-NetTCPConnection -LocalPort 1080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ("  Port 1080 listen (SOCKS): {0}" -f ([bool]$listen1080))

Write-Host ''
Write-Host '=== Step 9-10 ===' -ForegroundColor Cyan
Write-Host '  Manual: browser SOCKS5 127.0.0.1:1080 + https://ifconfig.me'
Write-Host '  Manual: reboot test per ARCHITECTURE.md Step 10'
