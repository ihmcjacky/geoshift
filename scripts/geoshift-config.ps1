# GeoShift configuration wizard for Windows.
# Usage: geoshift config              (interactive menu)
#        geoshift-config.ps1 full     (run all sections in sequence, called by installer)
# Requires: geoshift.env populated with at least GEOSHIFT_CONFIG_DIR.

$ErrorActionPreference = 'Stop'

$InstallDir = 'C:\Program Files\GeoShift'
$EnvFile    = 'C:\ProgramData\GeoShift\geoshift.env'
$MihomoExe  = "$InstallDir\mihomo.exe"

# ---- env helpers -------------------------------------------------------

function Read-EnvVars {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
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

function Write-EnvVar {
    param([string]$Path, [string]$Key, [string]$Value)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if (-not (Test-Path $Path)) {
        [System.IO.File]::WriteAllText($Path, "$Key=$Value`r`n", $utf8NoBom)
        return
    }
    $lines  = Get-Content $Path
    $found  = $false
    $result = foreach ($line in $lines) {
        if ($line -match "^\s*$Key\s*=") {
            "$Key=$Value"
            $found = $true
        } else {
            $line
        }
    }
    if (-not $found) { $result = @($result) + "$Key=$Value" }
    [System.IO.File]::WriteAllLines($Path, [string[]]$result, $utf8NoBom)
}

# ---- SSH key permission helper (same logic as install.ps1) -------------

function Set-SshKeyPermissionsForSystem {
    param([string]$KeyPath)
    if (-not (Test-Path $KeyPath)) {
        Write-Host "  SSH key not found at $KeyPath, skipping" -ForegroundColor Yellow
        return
    }
    try {
        $acl        = Get-Acl $KeyPath
        $systemSid  = [System.Security.Principal.SecurityIdentifier]'S-1-5-18'
        $systemAcct = $systemSid.Translate([System.Security.Principal.NTAccount])
        $acl.SetOwner($systemAcct)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { $acl.RemoveAccessRule($r) | Out-Null }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $systemSid, 'Read', 'None', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl $KeyPath $acl
        Write-Host "  SSH key permissions fixed: owner=SYSTEM, ACL=SYSTEM:Read" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not fix SSH key permissions: $_" -ForegroundColor Yellow
    }
}

# ---- NordVPN apply routine (canonical, used by install + sync too) -----

function Invoke-NordVpnApply {
    param([string]$ConfigYaml)
    if (-not (Test-Path $ConfigYaml)) {
        Write-Host "  config.yaml not found at $ConfigYaml, skipping NordVPN apply" -ForegroundColor Yellow
        return
    }

    $env = Read-EnvVars $EnvFile

    $enabled  = ($env['NORDVPN_ENABLED'] -eq 'true')
    $user     = $env['NORDVPN_SERVICE_USERNAME']
    $pass     = $env['NORDVPN_SERVICE_PASSWORD']
    $server   = if ($env['NORDVPN_PROXY_SERVER']) { $env['NORDVPN_PROXY_SERVER'] } else { 'jp874.proxy.nordvpn.com' }
    $port     = if ($env['NORDVPN_PROXY_PORT'])   { $env['NORDVPN_PROXY_PORT']   } else { '89' }

    $credsOk  = ($enabled -and $user -and $pass `
        -and $user -notmatch 'your-|YOUR_NORDVPN' `
        -and $pass -notmatch 'your-|YOUR_NORDVPN')

    $cfg = [System.IO.File]::ReadAllText($ConfigYaml, (New-Object System.Text.UTF8Encoding($false)))

    if ($credsOk) {
        # Inject server, port, username, password into the NordVPN-JP proxy block.
        # Each field is replaced line-by-line within the block boundary.
        $cfg = $cfg -replace '(?m)(- name: NordVPN-JP\r?\n(?:.*\r?\n)*?    server:)\s*.+', "`$1 $server"
        $cfg = $cfg -replace '(?m)(- name: NordVPN-JP\r?\n(?:.*\r?\n)*?    port:)\s*.+',   "`$1 $port"
        $cfg = $cfg -replace '(?m)(- name: NordVPN-JP\r?\n(?:.*\r?\n)*?    username:)\s*.+', "`$1 `"$user`""
        $cfg = $cfg -replace '(?m)(- name: NordVPN-JP\r?\n(?:.*\r?\n)*?    password:)\s*.+', "`$1 `"$pass`""

        # Restore JP-STRICT preferred order: NordVPN-JP first
        $cfg = $cfg -replace `
            '(?m)(  - name: JP-STRICT\r?\n    type: select\r?\n    proxies:\r?\n)(?:      - [^\r\n]+\r?\n)+', `
            "`$1      - NordVPN-JP`n      - JP-TUNNEL`n      - DIRECT`n"

        Write-Host "  NordVPN credentials injected; JP-STRICT prefers NordVPN-JP." -ForegroundColor Green
    } else {
        # Leave NordVPN-JP proxy block untouched (placeholder creds stay, valid YAML).
        # Demote JP-STRICT so it uses JP-TUNNEL first (best-effort, never hangs on NordVPN).
        $cfg = $cfg -replace `
            '(?m)(  - name: JP-STRICT\r?\n    type: select\r?\n    proxies:\r?\n)(?:      - [^\r\n]+\r?\n)+', `
            "`$1      - JP-TUNNEL`n      - NordVPN-JP`n      - DIRECT`n"

        Write-Host "  NordVPN disabled: JP-STRICT will use JP-TUNNEL first (best-effort)." -ForegroundColor Yellow
        Write-Host "  NOTE: Abema and similar sites block datacenter IPs." -ForegroundColor Yellow
        Write-Host "  To enable NordVPN later: geoshift config -> option 2" -ForegroundColor Yellow
    }

    [System.IO.File]::WriteAllText($ConfigYaml, $cfg, (New-Object System.Text.UTF8Encoding($false)))
}

# Exported so install.ps1 and geoshift-sync.ps1 can dot-source this file and call it.
Set-Variable -Name 'GeoShiftNordVpnApplyLoaded' -Value $true -Scope Global

# ---- custom rule file helper -------------------------------------------

function Ensure-CustomRuleFile {
    param([string]$Path, [string]$Group, [string]$Category)
    if (Test-Path $Path) { return }
    $header = "# GeoShift custom rules (user-managed). NOT overwritten by 'geoshift sync'."
    $note   = "# Routed to $Group alongside repo-managed $Category.yaml."
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, [string[]]@($header, $note, 'payload: []'), $utf8NoBom)
    Write-Host "  Created $Path" -ForegroundColor Green
}

function Count-RuleDomains {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $count = 0
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*- (DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR)') { $count++ }
    }
    return $count
}

function Add-CustomDomains {
    param([string]$Path, [string]$Group, [string]$Category)
    Ensure-CustomRuleFile -Path $Path -Group $Group -Category $Category

    Write-Host ""
    Write-Host "  Enter domains to add (one per line)." -ForegroundColor Cyan
    Write-Host "  Plain domain (e.g. example.com) becomes DOMAIN-SUFFIX,example.com" -ForegroundColor Cyan
    Write-Host "  Full rule (e.g. DOMAIN,api.example.com) is kept as-is." -ForegroundColor Cyan
    Write-Host "  Press Enter on an empty line when done." -ForegroundColor Cyan
    Write-Host ""

    $newEntries = @()
    while ($true) {
        $input = Read-Host "  Domain"
        $input = $input.Trim()
        if ($input -eq '') { break }
        if ($input -match '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR),') {
            $newEntries += "  - $input"
        } else {
            $newEntries += "  - DOMAIN-SUFFIX,$input"
        }
    }

    if ($newEntries.Count -eq 0) {
        Write-Host "  No domains added." -ForegroundColor Yellow
        return
    }

    $lines  = Get-Content $Path
    $result = @()
    foreach ($line in $lines) {
        $result += $line
        if ($line -match '^payload:') {
            foreach ($entry in $newEntries) { $result += $entry }
        }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, [string[]]$result, $utf8NoBom)
    Write-Host "  Added $($newEntries.Count) domain(s) to $Path" -ForegroundColor Green
}

# ---- prompt helper -----------------------------------------------------

function Prompt-EnvValue {
    param(
        [string]$Key,
        [string]$Description,
        [string]$Default = '',
        [switch]$Secret
    )
    $env     = Read-EnvVars $EnvFile
    $current = if ($env[$Key]) { $env[$Key] } else { $Default }
    $display = if ($Secret -and $current -and $current -notmatch 'your-|YOUR_') { '********' } else { $current }

    Write-Host ""
    Write-Host "  $Description" -ForegroundColor Cyan
    if ($display) { Write-Host "  Current: $display" -ForegroundColor DarkGray }
    $input = Read-Host "  Value (Enter to keep)"
    $input = $input.Trim()
    if ($input -ne '') {
        Write-EnvVar -Path $EnvFile -Key $Key -Value $input
        return $input
    }
    return $current
}

# ---- wizard sections ---------------------------------------------------

function Invoke-SectionServer {
    Write-Host ""
    Write-Host "--- Server & SSH Settings ---" -ForegroundColor White

    Prompt-EnvValue -Key 'US_HOST'   -Description 'US exit node IPv4 address'
    Prompt-EnvValue -Key 'SSH_USER'  -Description 'SSH username (default: ubuntu)' -Default 'ubuntu'

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    $usKey = Prompt-EnvValue -Key 'US_SSH_KEY' -Description 'Path to US SSH private key (.pem) - Windows path for scheduled task'
    if ($isAdmin -and $usKey -match '^[A-Za-z]:\\') {
        Set-SshKeyPermissionsForSystem -KeyPath $usKey
    }

    Prompt-EnvValue -Key 'JP_HOST'   -Description 'JP exit node IPv4 address'
    $jpKey = Prompt-EnvValue -Key 'JP_SSH_KEY' -Description 'Path to JP SSH private key (.pem) - Windows path for scheduled task'
    if ($isAdmin -and $jpKey -match '^[A-Za-z]:\\') {
        Set-SshKeyPermissionsForSystem -KeyPath $jpKey
    }

    $env = Read-EnvVars $EnvFile
    $configDir = $env['GEOSHIFT_CONFIG_DIR']
    if ($configDir) {
        $cfgYaml = Join-Path $configDir 'config.yaml'
        if (Test-Path $cfgYaml) {
            Write-Host ""
            Write-Host "  Validating config..." -ForegroundColor Cyan
            $result = & $MihomoExe -t -d $configDir 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Config OK" -ForegroundColor Green
            } else {
                Write-Host $result -ForegroundColor Red
                Write-Host "  WARNING: mihomo -t failed. Fix config.yaml before starting services." -ForegroundColor Red
            }
        }
    }
}

function Invoke-SectionNordVpn {
    Write-Host ""
    Write-Host "--- NordVPN Proxy Settings ---" -ForegroundColor White
    Write-Host ""
    Write-Host "  JP-STRICT routing (Abema and similar sites) uses NordVPN as a residential" -ForegroundColor Cyan
    Write-Host "  JP proxy to bypass datacenter IP blocks. This requires a NordVPN subscription" -ForegroundColor Cyan
    Write-Host "  with service credentials (not your login password)." -ForegroundColor Cyan
    Write-Host "  Get them at: nordaccount.com -> NordVPN -> Set up manually -> Service credentials" -ForegroundColor Cyan

    $answer = Read-Host "  Do you have a NordVPN subscription with service credentials? [y/N]"
    $haveSub = $answer -match '^[Yy]'

    $env       = Read-EnvVars $EnvFile
    $configDir = $env['GEOSHIFT_CONFIG_DIR']
    $cfgYaml   = if ($configDir) { Join-Path $configDir 'config.yaml' } else { $null }

    if ($haveSub) {
        Write-EnvVar -Path $EnvFile -Key 'NORDVPN_ENABLED' -Value 'true'
        Prompt-EnvValue -Key 'NORDVPN_PROXY_SERVER' -Description 'NordVPN JP proxy hostname' -Default 'jp874.proxy.nordvpn.com'
        Prompt-EnvValue -Key 'NORDVPN_PROXY_PORT'   -Description 'NordVPN proxy port'        -Default '89'
        Prompt-EnvValue -Key 'NORDVPN_SERVICE_USERNAME' -Description 'NordVPN service username' -Secret
        Prompt-EnvValue -Key 'NORDVPN_SERVICE_PASSWORD' -Description 'NordVPN service password' -Secret
    } else {
        Write-EnvVar -Path $EnvFile -Key 'NORDVPN_ENABLED' -Value 'false'
        Write-Host ""
        Write-Host "  NordVPN disabled. JP-STRICT sites will use JP-TUNNEL (best-effort)." -ForegroundColor Yellow
        Write-Host "  You can enable NordVPN later by running: geoshift config -> option 2" -ForegroundColor Yellow
    }

    if ($cfgYaml -and (Test-Path $cfgYaml)) {
        Write-Host ""
        Write-Host "  Applying NordVPN settings to config.yaml..." -ForegroundColor Cyan
        Invoke-NordVpnApply -ConfigYaml $cfgYaml

        Write-Host "  Validating config..." -ForegroundColor Cyan
        $result = & $MihomoExe -t -d $configDir 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Config OK" -ForegroundColor Green
        } else {
            Write-Host $result -ForegroundColor Red
            Write-Host "  WARNING: mihomo -t failed. Fix config.yaml." -ForegroundColor Red
        }
    } else {
        Write-Host "  Skipping config.yaml apply (GEOSHIFT_CONFIG_DIR not set or config.yaml missing)." -ForegroundColor Yellow
        Write-Host "  Re-run install.ps1 or set GEOSHIFT_CONFIG_DIR in $EnvFile" -ForegroundColor Yellow
    }
}

function Invoke-SectionRules {
    Write-Host ""
    Write-Host "--- Custom Domain Rules ---" -ForegroundColor White

    $env       = Read-EnvVars $EnvFile
    $configDir = $env['GEOSHIFT_CONFIG_DIR']
    if (-not $configDir) {
        Write-Host "  GEOSHIFT_CONFIG_DIR not set in $EnvFile" -ForegroundColor Red
        Write-Host "  Run install.ps1 first, then use 'geoshift config'." -ForegroundColor Red
        return
    }

    $rulesDir = Join-Path $configDir 'rules'
    if (-not (Test-Path $rulesDir)) {
        Write-Host "  Rules directory not found: $rulesDir" -ForegroundColor Red
        return
    }

    $categories = @(
        @{ Name = 'us-ai';     Group = 'US-PROXY';  Label = 'US AI services' },
        @{ Name = 'jp-strict'; Group = 'JP-STRICT'; Label = 'JP strict (Abema-class)' },
        @{ Name = 'jp-content';Group = 'JP-PROXY';  Label = 'JP general content' }
    )

    foreach ($cat in $categories) {
        $defaultFile = Join-Path $rulesDir "$($cat.Name).yaml"
        $customFile  = Join-Path $rulesDir "$($cat.Name)-custom.yaml"
        Ensure-CustomRuleFile -Path $customFile -Group $cat.Group -Category $cat.Name

        $defCount    = Count-RuleDomains $defaultFile
        $custCount   = Count-RuleDomains $customFile

        Write-Host ""
        Write-Host "  [$($cat.Label)]" -ForegroundColor White
        Write-Host "    Default rules : $defCount domains" -ForegroundColor DarkGray
        Write-Host "    Custom rules  : $custCount domains" -ForegroundColor DarkGray

        Write-Host "    Options:" -ForegroundColor Cyan
        Write-Host "      a) Quick-add domains"
        Write-Host "      e) Open custom file in editor (notepad)"
        Write-Host "      s) Skip this category"
        $choice = Read-Host "    Choice [a/e/s]"
        switch ($choice.ToLower()) {
            'a' { Add-CustomDomains -Path $customFile -Group $cat.Group -Category $cat.Name }
            'e' {
                Write-Host "  Opening $customFile in notepad..." -ForegroundColor Cyan
                Start-Process notepad.exe -ArgumentList $customFile -Wait
                Write-Host "  Press Enter when you have finished editing..." -ForegroundColor Cyan
                Read-Host | Out-Null
            }
            default { Write-Host "    Skipped." -ForegroundColor DarkGray }
        }
    }

    $env       = Read-EnvVars $EnvFile
    $configDir = $env['GEOSHIFT_CONFIG_DIR']
    $cfgYaml   = Join-Path $configDir 'config.yaml'
    Write-Host ""
    Write-Host "  Validating config..." -ForegroundColor Cyan
    $ok = $true
    do {
        $result = & $MihomoExe -t -d $configDir 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Config OK" -ForegroundColor Green
            $ok = $true
        } else {
            Write-Host $result -ForegroundColor Red
            Write-Host "  mihomo -t failed. Fix your custom rule files and press Enter to retry, or Ctrl-C to abort." -ForegroundColor Red
            Read-Host | Out-Null
            $ok = $false
        }
    } while (-not $ok)
}

# ---- reload offer ------------------------------------------------------

function Offer-Reload {
    $env       = Read-EnvVars $EnvFile
    $configDir = $env['GEOSHIFT_CONFIG_DIR']
    if (-not $configDir) { return }

    $answer = Read-Host "  Reload Mihomo now? [Y/n]"
    if ($answer -notmatch '^[Nn]') {
        try {
            Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:9090/configs?force=true' `
                -ContentType 'application/json' -Body '{}' | Out-Null
            Write-Host "  Reloaded." -ForegroundColor Green
        } catch {
            Write-Host "  Mihomo API not reachable (services may not be running)." -ForegroundColor Yellow
        }
    }
}

# ---- main menu ---------------------------------------------------------

# When dot-sourced by install.ps1 or geoshift-sync.ps1 to load functions only,
# skip the interactive menu. Callers set $Global:GeoShiftLoadFunctionsOnly = $true
# before dot-sourcing and clear it after.
if ($Global:GeoShiftLoadFunctionsOnly) { return }

$mode = if ($args.Count -gt 0) { $args[0] } else { 'menu' }

if ($mode -eq 'full') {
    Write-Host ""
    Write-Host "GeoShift Full Configuration Wizard" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan
    Invoke-SectionServer
    Invoke-SectionNordVpn
    Invoke-SectionRules
    Write-Host ""
    Offer-Reload
    Write-Host ""
    Write-Host "Configuration complete." -ForegroundColor Green
    exit 0
}

# Interactive menu
while ($true) {
    Write-Host ""
    Write-Host "GeoShift Configuration" -ForegroundColor Cyan
    Write-Host "======================" -ForegroundColor Cyan
    Write-Host "  1) Server & SSH settings"
    Write-Host "  2) NordVPN proxy"
    Write-Host "  3) Custom domain rules"
    Write-Host "  4) Run full wizard (1 -> 2 -> 3)"
    Write-Host "  5) Open geoshift.env in editor"
    Write-Host "  6) Open config.yaml in editor"
    Write-Host "  q) Quit"
    Write-Host ""
    $choice = Read-Host "Choice"

    switch ($choice.ToLower()) {
        '1' { Invoke-SectionServer;  Offer-Reload }
        '2' { Invoke-SectionNordVpn; Offer-Reload }
        '3' { Invoke-SectionRules;   Offer-Reload }
        '4' {
            Invoke-SectionServer
            Invoke-SectionNordVpn
            Invoke-SectionRules
            Offer-Reload
        }
        '5' {
            Write-Host "Opening $EnvFile in notepad..." -ForegroundColor Cyan
            Start-Process notepad.exe -ArgumentList $EnvFile -Wait
        }
        '6' {
            $env = Read-EnvVars $EnvFile
            $cfgPath = if ($env['GEOSHIFT_CONFIG_DIR']) { Join-Path $env['GEOSHIFT_CONFIG_DIR'] 'config.yaml' } else { '' }
            if ($cfgPath -and (Test-Path $cfgPath)) {
                Write-Host "Opening $cfgPath in notepad..." -ForegroundColor Cyan
                Start-Process notepad.exe -ArgumentList $cfgPath -Wait
            } else {
                Write-Host "config.yaml not found. Set GEOSHIFT_CONFIG_DIR in $EnvFile first." -ForegroundColor Red
            }
        }
        'q' { exit 0 }
        default { Write-Host "  Unknown option: $choice" -ForegroundColor Red }
    }
}
