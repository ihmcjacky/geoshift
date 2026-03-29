# GeoShift: Launch Mihomo with the shared config directory.
# Runs as SYSTEM via Task Scheduler. Do not run interactively unless testing.

$ErrorActionPreference = 'Stop'

$EnvFile    = 'C:\ProgramData\GeoShift\geoshift.env'
$LogFile    = 'C:\ProgramData\GeoShift\logs\mihomo.log'
$CoreLog    = 'C:\ProgramData\GeoShift\logs\mihomo-core.log'
$StderrLog  = 'C:\ProgramData\GeoShift\logs\mihomo-stderr.log'
$MihomoExe  = 'C:\Program Files\GeoShift\mihomo.exe'
$WinTunDll  = 'C:\Program Files\GeoShift\wintun.dll'
$LogMaxBytes = 1MB

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $LogMaxBytes) {
        Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value $line
}

function Rotate-IfNeeded {
    param([string]$Path)
    if ((Test-Path $Path) -and (Get-Item $Path).Length -gt $LogMaxBytes) {
        Move-Item -Path $Path -Destination "$Path.1" -Force
    }
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
$configDir = if ($env['GEOSHIFT_CONFIG_DIR']) { $env['GEOSHIFT_CONFIG_DIR'] } else { 'C:\ProgramData\GeoShift\config' }

if (-not (Test-Path $MihomoExe)) {
    Write-Log "ERROR: mihomo.exe not found at $MihomoExe - run install.ps1 first"
    exit 1
}
if (-not (Test-Path $WinTunDll)) {
    Write-Log "ERROR: wintun.dll not found at $WinTunDll - run install.ps1 first"
    exit 1
}
if (-not (Test-Path "$configDir\config.yaml")) {
    Write-Log "ERROR: no config.yaml at $configDir\config.yaml"
    exit 1
}

# Mihomo does not support --log-file (unknown flag -> usage on stderr, exit 2).
# Capture console output to mihomo-core.log instead.
Rotate-IfNeeded $CoreLog
if (Test-Path $CoreLog) { Remove-Item $CoreLog -Force -ErrorAction SilentlyContinue }

Write-Log "Starting mihomo with config dir: $configDir"

try {
    if (Test-Path $StderrLog) { Remove-Item $StderrLog -Force -ErrorAction SilentlyContinue }
    $proc = Start-Process -FilePath $MihomoExe `
        -ArgumentList @('-d', $configDir) `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $CoreLog `
        -RedirectStandardError $StderrLog
    Write-Log "mihomo exited (code $($proc.ExitCode))"
    if ($proc.ExitCode -ne 0) {
        if (Test-Path $CoreLog) {
            Write-Log '--- last lines from mihomo-core.log ---'
            Get-Content $CoreLog -ErrorAction SilentlyContinue | Select-Object -Last 15 | ForEach-Object { Write-Log "core: $_" }
        }
        if (Test-Path $StderrLog) {
            Write-Log '--- mihomo stderr ---'
            Get-Content $StderrLog -ErrorAction SilentlyContinue | Select-Object -Last 40 | ForEach-Object { Write-Log "stderr: $_" }
        }
    }
} catch {
    Write-Log "ERROR: $_"
    exit 1
}
