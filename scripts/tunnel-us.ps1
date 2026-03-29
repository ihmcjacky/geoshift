# GeoShift: Persistent SSH SOCKS5 tunnel to US Lightsail on localhost:1080.
# Runs as SYSTEM via Task Scheduler. Do not run interactively unless testing.

$ErrorActionPreference = 'Stop'

$EnvFile = 'C:\ProgramData\GeoShift\geoshift.env'
$LogFile = 'C:\ProgramData\GeoShift\logs\tunnel-us.log'
$SshErrLog = 'C:\ProgramData\GeoShift\logs\tunnel-us-ssh.err'
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

$lightsailIp = $env['US_LIGHTSAIL_IP']
$sshKey      = $env['SSH_PRIVATE_KEY']
$sshUser     = if ($env['SSH_USER']) { $env['SSH_USER'] } else { 'ubuntu' }

if (-not $lightsailIp) { Write-Log "ERROR: US_LIGHTSAIL_IP not set in $EnvFile"; exit 1 }
if (-not $sshKey)      { Write-Log "ERROR: SSH_PRIVATE_KEY not set in $EnvFile"; exit 1 }
if (-not (Test-Path $sshKey)) { Write-Log "ERROR: SSH key not found: $sshKey"; exit 1 }

Write-Log "Starting tunnel to ${sshUser}@${lightsailIp}"

while ($true) {
    try {
        if (Test-Path $SshErrLog) { Remove-Item $SshErrLog -Force -ErrorAction SilentlyContinue }
        $proc = Start-Process -FilePath 'ssh.exe' `
            -ArgumentList @('-i', $sshKey, '-D', '1080', '-N',
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
