<#
    dsh-web-desktop - Windows uninstaller.

    Stops the launcher's server (if it is running), removes the shortcuts this
    project created, and deletes the install directory.

    Usage
      .\windows\uninstall.ps1
      .\windows\uninstall.ps1 -InstallDir C:\tools\dsh-web-desktop
      .\windows\uninstall.ps1 -KeepLogs

    It never touches your dsh installation, your ~/.dsh profile, or any plugin
    you installed with `dsh plugin`.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$KeepLogs,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { if (-not $Quiet) { Write-Host $Message } }

$userProfile = [Environment]::GetFolderPath('UserProfile')
if (-not $userProfile) { $userProfile = $env:USERPROFILE }
if (-not $userProfile) { $userProfile = $HOME }
if (-not $userProfile) { throw 'cannot resolve the user profile directory' }
if (-not $InstallDir) { $InstallDir = Join-Path $userProfile '.dsh\launchers' }

$startMenu = [Environment]::GetFolderPath('Programs')
$desktop = [Environment]::GetFolderPath('Desktop')
$launcher = Join-Path $InstallDir 'dsh-web.ps1'

Write-Step 'dsh-web-desktop uninstaller'
Write-Step ''

# Stop a server this launcher started, so the files are not in use and no
# hidden process is left behind. The port comes from the install record: using a
# hard-coded default could stop a different dsh instance.
$port = 3080
$settingsPath = Join-Path $InstallDir 'install.json'
if (Test-Path $settingsPath) {
    try {
        $recorded = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($recorded.port) { $port = [int]$recorded.port }
        Write-Step ("  install record: port {0}, workspace {1}" -f $port, $recorded.workspace)
    } catch {
        Write-Step ("  install record unreadable, assuming port {0}" -f $port)
    }
} else {
    Write-Step ("  no install record found, assuming port {0}" -f $port)
}

if (Test-Path $launcher) {
    Write-Step ("  stopping the launcher server on port {0} (if any) ..." -f $port)
    try {
        & (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') `
            -NoProfile -ExecutionPolicy Bypass -File $launcher -Stop -Port $port -Quiet 2>&1 | ForEach-Object { Write-Step ("    {0}" -f $_) }
    } catch {
        Write-Step ("    stop failed (continuing): {0}" -f $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 500
}

# Only remove shortcuts that actually point at THIS install directory. Someone
# who installed with -NoStartMenuShortcut, or who has an unrelated shortcut with
# the same name, must not lose it.
$shell = New-Object -ComObject WScript.Shell
$shortcuts = @()
if ($startMenu) {
    $shortcuts += (Join-Path $startMenu 'DSH Web.lnk')
    $shortcuts += (Join-Path $startMenu 'DSH Web (Stop).lnk')
    # Shipped by an earlier version; listed so upgrading users still get it
    # cleaned up if the installer never ran again.
    $shortcuts += (Join-Path $startMenu 'DSH Web (Restart).lnk')
}
if ($desktop) {
    $shortcuts += (Join-Path $desktop 'DSH Web.lnk')
    $shortcuts += (Join-Path $desktop 'DSH Web (Restart).lnk')
}

foreach ($shortcut in $shortcuts) {
    if (-not (Test-Path $shortcut)) { continue }
    $owned = $false
    try {
        $target = $shell.CreateShortcut($shortcut).Arguments
        if ($target -and $target -like "*$InstallDir*") { $owned = $true }
    } catch { }
    if ($owned) {
        Remove-Item $shortcut -Force
        Write-Step ("  removed {0}" -f $shortcut)
    } else {
        Write-Step ("  kept {0} (it does not point at this install)" -f $shortcut)
    }
}

if (Test-Path $InstallDir) {
    if ($KeepLogs) {
        Get-ChildItem $InstallDir -File |
            Where-Object { $_.Name -notlike 'dsh-web*.log' -and $_.Name -ne 'install.json' } |
            Remove-Item -Force
        Write-Step ("  kept logs in {0}" -f (Join-Path $InstallDir 'logs'))
    } else {
        # A running dsh still holds its redirected stdout/stderr, so the first
        # attempt can fail; retry once and report instead of throwing.
        $removed = $false
        foreach ($attempt in 1..2) {
            try {
                Remove-Item $InstallDir -Recurse -Force -ErrorAction Stop
                $removed = $true
                break
            } catch {
                Write-Step ("  could not delete everything (attempt {0}): {1}" -f $attempt, $_.Exception.Message)
                Start-Sleep -Milliseconds 800
            }
        }
        if ($removed) {
            Write-Step ("  removed {0}" -f $InstallDir)
        } else {
            Write-Step ("  left {0} in place - stop any running dsh server and delete it by hand" -f $InstallDir)
        }
    }
} else {
    Write-Step ("  nothing to remove at {0}" -f $InstallDir)
}

Write-Step ''
Write-Step 'Done. The plugin part, if you installed it, is removed with:'
Write-Step '  dsh plugin --profile web remove dsh-web-desktop'
Write-Step ''
