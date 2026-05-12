# GeoShift CLI for Windows.
# Usage: geoshift <command>
# Or directly: powershell -ExecutionPolicy Bypass -File geoshift.ps1 <command>

$ErrorActionPreference = 'Stop'

$InstallDir = 'C:\Program Files\GeoShift'
$MihomoApi  = 'http://127.0.0.1:9090'

$Tasks = @('GeoShift-Tunnel-US', 'GeoShift-Tunnel-JP', 'GeoShift-Mihomo')

function usage {
    Write-Host 'Usage: geoshift <command>'
    Write-Host ''
    Write-Host 'Commands (no elevated privileges required unless noted):'
    Write-Host '  sync     Fetch latest config and rules from GitHub, write to config dir'
    Write-Host '  reload   Reload Mihomo config via REST API (no restart needed)'
    Write-Host '  status   Show running/stopped state of all GeoShift scheduled tasks'
    Write-Host '  start    Start all GeoShift scheduled tasks  [requires Administrator]'
    Write-Host '  stop     Stop all GeoShift scheduled tasks   [requires Administrator]'
    Write-Host '  restart  Stop then re-start all tasks in correct order  [requires Administrator]'
    exit 1
}

function Invoke-TaskOp {
    param([string]$Op)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "geoshift: '$Op' requires Administrator privileges." -ForegroundColor Red
        Write-Host "Re-run this command from an elevated prompt."
        exit 1
    }
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
    'status' {
        foreach ($name in $Tasks) {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($task) {
                $state = $task.State
                $color = if ($state -eq 'Running') { 'Green' } else { 'Yellow' }
                Write-Host ("  {0,-25} {1}" -f $name, $state) -ForegroundColor $color
            } else {
                Write-Host ("  {0,-25} {1}" -f $name, 'NOT FOUND') -ForegroundColor Red
            }
        }
    }
    'stop' {
        Invoke-TaskOp 'stop'
        # Stop Mihomo first (it depends on tunnels), then tunnels
        $stopOrder = @('GeoShift-Mihomo', 'GeoShift-Tunnel-US', 'GeoShift-Tunnel-JP')
        foreach ($name in $stopOrder) {
            Write-Host "  Stopping $name..."
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        }
        Write-Host 'geoshift: all tasks stopped.'
    }
    'start' {
        Invoke-TaskOp 'start'
        # Start tunnels first; give them a moment before Mihomo
        $tunnelTasks = @('GeoShift-Tunnel-US', 'GeoShift-Tunnel-JP')
        foreach ($name in $tunnelTasks) {
            Write-Host "  Starting $name..."
            Start-ScheduledTask -TaskName $name
        }
        Write-Host '  Waiting 5 s for tunnels to come up...'
        Start-Sleep -Seconds 5
        Write-Host '  Starting GeoShift-Mihomo...'
        Start-ScheduledTask -TaskName 'GeoShift-Mihomo'
        Write-Host 'geoshift: all tasks started.'
    }
    'restart' {
        Invoke-TaskOp 'restart'
        Write-Host 'geoshift: stopping all tasks...'
        $stopOrder = @('GeoShift-Mihomo', 'GeoShift-Tunnel-US', 'GeoShift-Tunnel-JP')
        foreach ($name in $stopOrder) {
            Write-Host "  Stopping $name..."
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        }
        $tunnelTasks = @('GeoShift-Tunnel-US', 'GeoShift-Tunnel-JP')
        foreach ($name in $tunnelTasks) {
            Write-Host "  Starting $name..."
            Start-ScheduledTask -TaskName $name
        }
        Write-Host '  Waiting 5 s for tunnels to come up...'
        Start-Sleep -Seconds 5
        Write-Host '  Starting GeoShift-Mihomo...'
        Start-ScheduledTask -TaskName 'GeoShift-Mihomo'
        Write-Host 'geoshift: all tasks restarted.'
    }
    default {
        Write-Host "geoshift: unknown command: $cmd" -ForegroundColor Red
        usage
    }
}
