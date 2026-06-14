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
Write-Host ("  Port 9090 listen (Mihomo API): {0}" -f ([bool]$listen9090))
$listen1080 = Get-NetTCPConnection -LocalPort 1080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ("  Port 1080 listen (US SOCKS5):  {0}" -f ([bool]$listen1080))
$listen1081 = Get-NetTCPConnection -LocalPort 1081 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ("  Port 1081 listen (JP SOCKS5):  {0}" -f ([bool]$listen1081))
if (-not $listen1081) {
    Write-Host '  WARNING: JP tunnel not listening on 1081 - Abema geo check will fail!' -ForegroundColor Red
}

Write-Host ''
Write-Host '=== Step 9: Tunnel exit-IP check ===' -ForegroundColor Cyan
Write-Host '  Checking IP seen through JP tunnel (socks5h://127.0.0.1:1081)...'
if ($listen1081) {
    $curlExe = (Get-Command curl.exe -ErrorAction SilentlyContinue)?.Source
    if ($curlExe) {
        try {
            $jpIp = (& $curlExe -s --max-time 10 -x socks5h://127.0.0.1:1081 https://ifconfig.me/ip 2>&1).Trim()
            if ($jpIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                Write-Host ("  JP tunnel exit IP: {0}" -f $jpIp) -ForegroundColor Green
                Write-Host '  Check if this is Japanese: https://ipinfo.io'
            } else {
                Write-Host ("  JP tunnel curl returned unexpected output: {0}" -f $jpIp) -ForegroundColor Red
            }
        } catch {
            Write-Host ("  JP tunnel curl failed: {0}" -f $_) -ForegroundColor Red
        }
    } else {
        Write-Host '  curl.exe not found - run manually (see below).' -ForegroundColor Yellow
    }
} else {
    Write-Host '  Skipped (port 1081 not listening).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  To test JP tunnel manually (run in a new prompt):'
Write-Host '    curl -x socks5h://127.0.0.1:1081 https://ifconfig.me'
Write-Host '  Expected: a Japanese IP address (103.x.x.x, 126.x.x.x, 153.x.x.x, etc.)'
