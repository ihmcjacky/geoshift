# GeoShift rule sync - fetch latest rule files from GitHub.
# Non-fatal: cached version is kept if a download fails.
# Usage: powershell -ExecutionPolicy Bypass -File geoshift-sync.ps1

$ErrorActionPreference = 'Stop'

$RepoRaw = 'https://raw.githubusercontent.com/ihmcjacky/geoshift/master'

# config.yaml fetched to ConfigDir root (not rules/)
$ConfigFiles = @(
    'config/config.yaml'
)

$RuleFiles = @(
    'config/rules/jp-strict.yaml',
    'config/rules/jp-strict.txt',
    'config/rules/jp-content.yaml',
    'config/rules/jp-content.txt',
    'config/rules/us-ai.yaml',
    'config/rules/us-ai.txt'
)

$EnvFile   = 'C:\ProgramData\GeoShift\geoshift.env'
$ConfigDir = $null

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

if (Test-Path $EnvFile) {
    $envVars = Read-EnvFile $EnvFile
    if ($envVars['GEOSHIFT_CONFIG_DIR']) {
        $ConfigDir = $envVars['GEOSHIFT_CONFIG_DIR']
    }
}

if (-not $ConfigDir) {
    Write-Warning 'geoshift-sync: GEOSHIFT_CONFIG_DIR not set in geoshift.env'
    exit 1
}

$RulesDir = Join-Path $ConfigDir 'rules'
if (-not (Test-Path $RulesDir)) {
    Write-Warning "geoshift-sync: rules directory not found: $RulesDir"
    exit 1
}

Write-Host 'geoshift-sync: fetching config and rules from GitHub...'
$anyFailed = $false

foreach ($cfgPath in $ConfigFiles) {
    $filename = Split-Path $cfgPath -Leaf
    $url  = "$RepoRaw/$cfgPath"
    $dest = Join-Path $ConfigDir $filename
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 15
        Write-Host "  updated: $filename"
    } catch {
        Write-Warning "  failed to fetch $filename (keeping cached version): $_"
        $anyFailed = $true
    }
}

foreach ($rulePath in $RuleFiles) {
    $filename = Split-Path $rulePath -Leaf
    $url  = "$RepoRaw/$rulePath"
    $dest = Join-Path $RulesDir $filename
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 15
        Write-Host "  updated: $filename"
    } catch {
        Write-Warning "  failed to fetch $filename (keeping cached version): $_"
        $anyFailed = $true
    }
}

if (-not $anyFailed) {
    Write-Host 'geoshift-sync: all files up to date'
} else {
    Write-Warning 'geoshift-sync: completed with warnings - some files may be stale'
}

# Re-apply local NordVPN settings from geoshift.env.
# geoshift sync overwrites config.yaml with the credential-free repo copy;
# this restores credentials and JP-STRICT order so they are never lost after a sync.
$wizardScript = Join-Path (Split-Path $EnvFile) '..\..\..\Program Files\GeoShift\geoshift-config.ps1' -Resolve -ErrorAction SilentlyContinue
if (-not $wizardScript -or -not (Test-Path $wizardScript)) {
    $wizardScript = 'C:\Program Files\GeoShift\geoshift-config.ps1'
}
if (Test-Path $wizardScript) {
    $Global:GeoShiftLoadFunctionsOnly = $true
    . $wizardScript
    $Global:GeoShiftLoadFunctionsOnly = $false
    $cfgPath = Join-Path $ConfigDir 'config.yaml'
    if (Test-Path $cfgPath) {
        Write-Host 'geoshift-sync: re-applying NordVPN settings from geoshift.env...'
        Invoke-NordVpnApply -ConfigYaml $cfgPath
        $result = & 'C:\Program Files\GeoShift\mihomo.exe' -t -d $ConfigDir 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host 'geoshift-sync: config validated OK'
        } else {
            Write-Warning "geoshift-sync: mihomo -t failed after sync:`n$result"
        }
    }
} else {
    Write-Warning 'geoshift-sync: geoshift-config.ps1 not found, skipping NordVPN re-apply'
}
