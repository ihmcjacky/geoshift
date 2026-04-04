# GeoShift CLI for Windows.
# Usage: geoshift sync | geoshift reload
# Or directly: powershell -ExecutionPolicy Bypass -File geoshift.ps1 <command>

$ErrorActionPreference = 'Stop'

$InstallDir = 'C:\Program Files\GeoShift'
$MihomoApi  = 'http://127.0.0.1:9090'

function usage {
    Write-Host 'Usage: geoshift <command>'
    Write-Host '  sync    fetch latest rules from GitHub'
    Write-Host '  reload  reload Mihomo config via API'
    exit 1
}

$cmd = if ($args.Count -gt 0) { $args[0] } else { '' }
if (-not $cmd) { usage }

switch ($cmd) {
    'sync' {
        $syncScript = Join-Path $InstallDir 'geoshift-sync.ps1'
        if (-not (Test-Path $syncScript)) {
            Write-Host "geoshift: sync script not found at $syncScript" -ForegroundColor Red
            exit 1
        }
        & powershell.exe -NonInteractive -ExecutionPolicy Bypass -File $syncScript
    }
    'reload' {
        Write-Host 'geoshift: reloading Mihomo config...'
        try {
            Invoke-RestMethod -Method Put -Uri "$MihomoApi/configs?force=true" `
                -ContentType 'application/json' -Body '{}' | Out-Null
            Write-Host 'geoshift: reloaded via API'
        } catch {
            Write-Warning "geoshift: API not reachable ($_)"
            Write-Host 'To reload manually, restart the GeoShift-Mihomo scheduled task:'
            Write-Host '  Start-ScheduledTask -TaskName GeoShift-Mihomo'
        }
    }
    default {
        Write-Host "geoshift: unknown command: $cmd" -ForegroundColor Red
        usage
    }
}
