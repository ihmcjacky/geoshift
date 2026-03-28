# GeoShift Windows Installer. Run once as Administrator.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\install.ps1

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

$InstallDir = 'C:\Program Files\GeoShift'
$DataDir    = 'C:\ProgramData\GeoShift'
$LogDir     = "$DataDir\logs"
$ConfigDir  = "$DataDir\config"
$EnvFile    = "$DataDir\geoshift.env"
$MihomoExe  = "$InstallDir\mihomo.exe"
$WinTunDll  = "$InstallDir\wintun.dll"

function die {
    param([string]$msg)
    Write-Host "geoshift install: $msg" -ForegroundColor Red
    exit 1
}

function info {
    param([string]$msg)
    Write-Host "==> $msg" -ForegroundColor Cyan
}

# ── Step 1: Create directories ────────────────────────────────────────────────
info "Creating directories"
@($InstallDir, $DataDir, $LogDir, $ConfigDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ── Step 2: Download Mihomo ───────────────────────────────────────────────────
info "Downloading latest Mihomo (windows-amd64)"
$releaseApi = 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'
$release = Invoke-RestMethod -Uri $releaseApi -UseBasicParsing
$asset = $release.assets | Where-Object {
    $_.name -match '^mihomo-windows-amd64-v[\d.]+\.zip$'
} | Select-Object -First 1

if (-not $asset) { die "Could not find Mihomo windows-amd64 asset in latest release" }

$tmpZip = Join-Path $env:TEMP 'mihomo-windows.zip'
$tmpDir = Join-Path $env:TEMP 'mihomo-extract'
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip -UseBasicParsing
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
Expand-Archive -Path $tmpZip -DestinationPath $tmpDir
$exeSrc = Get-ChildItem $tmpDir -Filter 'mihomo*.exe' -Recurse | Select-Object -First 1
if (-not $exeSrc) { die "mihomo.exe not found in downloaded zip" }
Copy-Item $exeSrc.FullName -Destination $MihomoExe -Force
Remove-Item $tmpZip, $tmpDir -Recurse -Force

# ── Step 3: Download WinTun DLL ───────────────────────────────────────────────
info "Downloading WinTun"
$wintunUrl = 'https://www.wintun.net/builds/wintun-0.14.1.zip'
$wintunZip = Join-Path $env:TEMP 'wintun.zip'
$wintunDir = Join-Path $env:TEMP 'wintun-extract'
Invoke-WebRequest -Uri $wintunUrl -OutFile $wintunZip -UseBasicParsing
if (Test-Path $wintunDir) { Remove-Item $wintunDir -Recurse -Force }
Expand-Archive -Path $wintunZip -DestinationPath $wintunDir
# WinTun zip has amd64/wintun.dll
$dllSrc = Get-ChildItem $wintunDir -Filter 'wintun.dll' -Recurse |
    Where-Object { $_.DirectoryName -match 'amd64' } |
    Select-Object -First 1
if (-not $dllSrc) { die "wintun.dll (amd64) not found in downloaded zip" }
Copy-Item $dllSrc.FullName -Destination $WinTunDll -Force
Remove-Item $wintunZip, $wintunDir -Recurse -Force

# ── Step 4: Copy scripts ──────────────────────────────────────────────────────
info "Copying PowerShell scripts"
$scriptSrc = Split-Path -Parent $PSCommandPath
Copy-Item "$scriptSrc\tunnel-us.ps1"  -Destination $InstallDir -Force
Copy-Item "$scriptSrc\mihomo-run.ps1" -Destination $InstallDir -Force

# ── Step 5: Set up env file ───────────────────────────────────────────────────
info "Setting up env file"
$envExample = Join-Path (Split-Path -Parent $scriptSrc) 'geoshift.env.example'
if (-not (Test-Path $EnvFile)) {
    if (Test-Path $envExample) {
        Copy-Item $envExample -Destination $EnvFile
    } else {
        @"
# GeoShift environment — fill in before starting services
US_LIGHTSAIL_IP=your.us.lightsail.ipv4
SSH_PRIVATE_KEY=C:\Users\$env:USERNAME\.ssh\lightsail.pem
SSH_USER=ubuntu
GEOSHIFT_CONFIG_DIR=$ConfigDir
"@ | Set-Content $EnvFile
    }
    Write-Host "  Created $EnvFile — EDIT THIS FILE before starting services" -ForegroundColor Yellow
} else {
    Write-Host "  $EnvFile already exists, not overwriting"
}

# ── Step 6: Copy config if not present ───────────────────────────────────────
info "Checking config directory"
$repoConfig = Join-Path (Split-Path -Parent $scriptSrc) 'config'
if ((Test-Path $repoConfig) -and -not (Test-Path "$ConfigDir\config.yaml")) {
    Copy-Item "$repoConfig\*" -Destination $ConfigDir -Recurse -Force
    Write-Host "  Copied config to $ConfigDir"
} elseif (Test-Path "$ConfigDir\config.yaml") {
    Write-Host "  Config already present at $ConfigDir"
} else {
    Write-Host "  WARNING: no config found — copy your config/ directory to $ConfigDir" -ForegroundColor Yellow
}

# ── Step 7: Register Task Scheduler tasks (W4) ───────────────────────────────
info "Registering Task Scheduler tasks"

$psExe = 'powershell.exe'
$psFlags = '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File'

function Register-GeoShiftTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [int]$DelaySeconds = 0
    )

    $action  = New-ScheduledTaskAction -Execute $psExe -Argument "$psFlags `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    if ($DelaySeconds -gt 0) {
        $trigger.Delay = "PT${DelaySeconds}S"
    }
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Seconds 5) `
        -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $params = @{
        TaskName  = $TaskName
        Action    = $action
        Trigger   = $trigger
        Settings  = $settings
        Principal = $principal
        Force     = $true
    }
    Register-ScheduledTask @params | Out-Null
    Write-Host "  Registered: $TaskName"
}

Register-GeoShiftTask -TaskName 'GeoShift-Tunnel-US' -ScriptPath "$InstallDir\tunnel-us.ps1"
Register-GeoShiftTask -TaskName 'GeoShift-Mihomo'    -ScriptPath "$InstallDir\mihomo-run.ps1" -DelaySeconds 10

# ── Step 8: Validate Mihomo config ───────────────────────────────────────────
if (Test-Path "$ConfigDir\config.yaml") {
    info "Validating Mihomo config"
    $result = & $MihomoExe -t -d $ConfigDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host $result
        die "mihomo -t failed — fix config.yaml before proceeding"
    }
    Write-Host "  Config OK"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Edit $EnvFile with your Lightsail IP and SSH key path"
Write-Host "  2. Ensure SSH key file is readable by SYSTEM"
Write-Host "     (icacls `"<key.pem>`" /grant `"SYSTEM:(R)`")"
Write-Host "  3. Reboot, or start tasks manually:"
Write-Host "     Start-ScheduledTask -TaskName GeoShift-Tunnel-US"
Write-Host "     Start-ScheduledTask -TaskName GeoShift-Mihomo"
Write-Host ""
Write-Host "Logs: $LogDir"
Write-Host "Stop:   Stop-ScheduledTask -TaskName GeoShift-Mihomo"
Write-Host "        Stop-ScheduledTask -TaskName GeoShift-Tunnel-US"
