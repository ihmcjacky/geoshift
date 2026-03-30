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

# Set SSH key file owner to SYSTEM and restrict ACL to SYSTEM-read-only.
# OpenSSH on Windows checks file *ownership* in addition to ACL permissions.
# If the owner is not SYSTEM (e.g. BUILTIN\Administrators from when the file
# was first copied), SSH rejects the key with "bad permissions" and falls back
# to password auth, which the server denies -> "Permission denied (publickey)".
function Set-SshKeyPermissionsForSystem {
    param([string]$KeyPath)
    if (-not (Test-Path $KeyPath)) {
        Write-Host "  SSH key not found at $KeyPath, skipping" -ForegroundColor Yellow
        return
    }
    try {
        $acl = Get-Acl $KeyPath

        # 1. Set owner to SYSTEM
        $systemSid     = [System.Security.Principal.SecurityIdentifier]'S-1-5-18'
        $systemAccount = $systemSid.Translate([System.Security.Principal.NTAccount])
        $acl.SetOwner($systemAccount)

        # 2. Remove inheritance; do NOT copy inherited ACEs
        $acl.SetAccessRuleProtection($true, $false)

        # 3. Remove all existing (now de-inherited) ACEs
        foreach ($r in @($acl.Access)) { $acl.RemoveAccessRule($r) | Out-Null }

        # 4. Grant SYSTEM Read only
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $systemSid, 'Read', 'None', 'None', 'Allow')
        $acl.AddAccessRule($rule)

        Set-Acl $KeyPath $acl
        Write-Host "  SSH key permissions fixed: owner=SYSTEM, ACL=SYSTEM:Read" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not auto-fix SSH key permissions: $_" -ForegroundColor Yellow
        Write-Host "  Run manually (as Administrator):" -ForegroundColor Yellow
        Write-Host "    `$acl = Get-Acl '$KeyPath'" -ForegroundColor Yellow
        Write-Host "    `$acl.SetOwner([System.Security.Principal.NTAccount]'NT AUTHORITY\SYSTEM')" -ForegroundColor Yellow
        Write-Host "    Set-Acl '$KeyPath' `$acl" -ForegroundColor Yellow
        Write-Host "    icacls '$KeyPath' /inheritance:r /grant:r 'NT AUTHORITY\SYSTEM:(R)'" -ForegroundColor Yellow
    }
}

# -- Step 1: Create directories -----------------------------------------------
info "Creating directories"
@($InstallDir, $DataDir, $LogDir, $ConfigDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# -- Step 2: Download Mihomo --------------------------------------------------
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

# -- Step 3: Download WinTun DLL ----------------------------------------------
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

# -- Step 4: Copy scripts -----------------------------------------------------
info "Copying PowerShell scripts"
$scriptSrc = Split-Path -Parent $PSCommandPath
Copy-Item "$scriptSrc\tunnel-us.ps1"  -Destination $InstallDir -Force
Copy-Item "$scriptSrc\mihomo-run.ps1" -Destination $InstallDir -Force

# -- Step 5: Set up env file --------------------------------------------------
info "Setting up env file"
$envExample = Join-Path (Split-Path -Parent $scriptSrc) 'geoshift.env.example'
if (-not (Test-Path $EnvFile)) {
    if (Test-Path $envExample) {
        Copy-Item $envExample -Destination $EnvFile
    } else {
        @"
# GeoShift environment - fill in before starting services
US_LIGHTSAIL_IP=your.us.lightsail.ipv4
SSH_PRIVATE_KEY=C:\Users\$env:USERNAME\.ssh\lightsail.pem
SSH_USER=ubuntu
GEOSHIFT_CONFIG_DIR=$ConfigDir
"@ | Set-Content $EnvFile
    }
    Write-Host "  Created $EnvFile - EDIT THIS FILE before starting services" -ForegroundColor Yellow
} else {
    Write-Host "  $EnvFile already exists, not overwriting"
}

# -- Step 5b: Fix SSH key permissions if key path is already set in env -------
# This handles re-runs of install.ps1 after the user has populated geoshift.env.
$envSshKey = $null
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        $line = $line.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { continue }
        if ($line -match '^SSH_PRIVATE_KEY\s*=\s*(.+)$') {
            $candidate = $Matches[1].Trim().Trim('"')
            # Skip placeholder / Linux-style paths
            if ($candidate -notmatch 'your\.|placeholder|^/' -and $candidate -match '^[A-Za-z]:\\') {
                $envSshKey = $candidate
            }
            break
        }
    }
}
if ($envSshKey) {
    info "Fixing SSH key permissions for SYSTEM"
    Set-SshKeyPermissionsForSystem -KeyPath $envSshKey
} else {
    Write-Host "  SSH_PRIVATE_KEY not yet configured in $EnvFile; skipping key permission step"
    Write-Host "  Re-run install.ps1 after setting SSH_PRIVATE_KEY, or call Set-SshKeyPermissionsForSystem manually."
}

# -- Step 6: Copy config if not present ---------------------------------------
info "Checking config directory"
$repoConfig = Join-Path (Split-Path -Parent $scriptSrc) 'config'
if ((Test-Path $repoConfig) -and -not (Test-Path "$ConfigDir\config.yaml")) {
    Copy-Item "$repoConfig\*" -Destination $ConfigDir -Recurse -Force
    Write-Host "  Copied config to $ConfigDir"
} elseif (Test-Path "$ConfigDir\config.yaml") {
    Write-Host "  Config already present at $ConfigDir"
} else {
    Write-Host "  WARNING: no config found - copy your config/ directory to $ConfigDir" -ForegroundColor Yellow
}

# -- Step 7: Register Task Scheduler tasks ------------------------------------
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
    # Default task settings often skip "At startup" on laptops on battery; allow AC or battery.
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
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

    # PowerShell 5.1 / Register-ScheduledTask does not reliably persist the
    # battery flags from New-ScheduledTaskSettingsSet. Patch them via
    # Set-ScheduledTask immediately after registration to guarantee the task
    # starts on battery and does not stop when the machine goes onto battery.
    $registered = Get-ScheduledTask -TaskName $TaskName
    $registered.Settings.DisallowStartIfOnBatteries = $false
    $registered.Settings.StopIfGoingOnBatteries      = $false
    Set-ScheduledTask -InputObject $registered | Out-Null

    Write-Host "  Registered: $TaskName"
}

# 30-second delay lets the NIC get an IP before ssh.exe tries to connect.
# Mihomo gets an extra 10 s on top of that to let the tunnel come up first.
Register-GeoShiftTask -TaskName 'GeoShift-Tunnel-US' -ScriptPath "$InstallDir\tunnel-us.ps1" -DelaySeconds 30
Register-GeoShiftTask -TaskName 'GeoShift-Mihomo'    -ScriptPath "$InstallDir\mihomo-run.ps1" -DelaySeconds 40

# -- Step 8: Validate Mihomo config -------------------------------------------
if (Test-Path "$ConfigDir\config.yaml") {
    info "Validating Mihomo config"
    $result = & $MihomoExe -t -d $ConfigDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host $result
        die "mihomo -t failed - fix config.yaml before proceeding"
    }
    Write-Host "  Config OK"
}

# -- Done ---------------------------------------------------------------------
Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Edit $EnvFile with your Lightsail IP and SSH key path"
Write-Host "  2. Re-run install.ps1 (as Administrator) so it sets the SSH key owner"
Write-Host "     to SYSTEM and locks the ACL. Or run manually:"
Write-Host "     `$acl = Get-Acl '<key.pem>'"
Write-Host "     `$acl.SetOwner([System.Security.Principal.NTAccount]'NT AUTHORITY\SYSTEM')"
Write-Host "     Set-Acl '<key.pem>' `$acl"
Write-Host "     icacls '<key.pem>' /inheritance:r /grant:r 'NT AUTHORITY\SYSTEM:(R)'"
Write-Host "     NOTE: icacls /grant alone is not enough - the file OWNER must also be SYSTEM."
Write-Host "  3. Reboot, or start tasks manually:"
Write-Host "     Start-ScheduledTask -TaskName GeoShift-Tunnel-US"
Write-Host "     Start-ScheduledTask -TaskName GeoShift-Mihomo"
Write-Host ""
Write-Host "Logs: $LogDir"
Write-Host "Stop:   Stop-ScheduledTask -TaskName GeoShift-Mihomo"
Write-Host "        Stop-ScheduledTask -TaskName GeoShift-Tunnel-US"
