# GeoShift: Persistent SSH SOCKS5 tunnel to JP Lightsail on localhost:1081.
# Runs as SYSTEM via Task Scheduler. Do not run interactively unless testing.

$ErrorActionPreference = 'Stop'

$EnvFile = 'C:\ProgramData\GeoShift\geoshift.env'
$LogFile = 'C:\ProgramData\GeoShift\logs\tunnel-jp.log'
$SshErrLog = 'C:\ProgramData\GeoShift\logs\tunnel-jp-ssh.err'
$LogMaxBytes = 1MB

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    # Rotate if over 1 MB
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $LogMaxBytes) {
        Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value $line
}

function Read-EnvFile {
    param([string]$Path)
    $vars = @{}
    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $vars[$key] = $val
    }
    return $vars
}

if (-not (Test-Path $EnvFile)) {
    Write-Log "ERROR: env file not found: $EnvFile"
    exit 1
}

$env = Read-EnvFile $EnvFile

$lightsailIp = $env['JP_LIGHTSAIL_IP']
$sshKey      = $env['JP_SSH_PRIVATE_KEY']
$sshUser     = if ($env['SSH_USER']) { $env['SSH_USER'] } else { 'ubuntu' }

if (-not $lightsailIp) { Write-Log "ERROR: JP_LIGHTSAIL_IP not set in $EnvFile"; exit 1 }
if (-not $sshKey)      { Write-Log "ERROR: JP_SSH_PRIVATE_KEY not set in $EnvFile"; exit 1 }
if (-not (Test-Path $sshKey)) { Write-Log "ERROR: SSH key not found: $sshKey"; exit 1 }

Write-Log "Starting JP tunnel to ${sshUser}@${lightsailIp}"

# Sync rules before connecting (non-fatal: cached rules used if download fails)
$syncScript = 'C:\Program Files\GeoShift\geoshift-sync.ps1'
if (Test-Path $syncScript) {
    try {
        Write-Log "Syncing rules from GitHub..."
        & powershell.exe -NonInteractive -ExecutionPolicy Bypass -File $syncScript
        Write-Log "Rule sync complete"
    } catch {
        Write-Log "Rule sync failed (continuing with cached rules): $_"
    }
} else {
    Write-Log "geoshift-sync.ps1 not found at $syncScript, skipping rule sync"
}

while ($true) {
    try {
        if (Test-Path $SshErrLog) { Remove-Item $SshErrLog -Force -ErrorAction SilentlyContinue }
        $proc = Start-Process -FilePath 'ssh.exe' `
            -ArgumentList @('-i', $sshKey, '-D', '1081', '-N',
                            '-o', 'StrictHostKeyChecking=accept-new',
                            '-o', 'ServerAliveInterval=15',
                            '-o', 'ServerAliveCountMax=3',
                            '-o', 'TCPKeepAlive=yes',
                            '-o', 'ExitOnForwardFailure=yes',
                            '-o', 'ConnectTimeout=30',
                            "${sshUser}@${lightsailIp}") `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardError $SshErrLog
        Write-Log "ssh.exe exited (code $($proc.ExitCode)), reconnecting in 5s"
        if ($proc.ExitCode -ne 0 -and (Test-Path $SshErrLog)) {
            Get-Content $SshErrLog -ErrorAction SilentlyContinue | Select-Object -Last 30 | ForEach-Object {
                Write-Log "ssh: $_"
            }
        }
    } catch {
        Write-Log "ERROR: $_. Retrying in 5s"
    }
    Start-Sleep -Seconds 5
}
