<#
    dsh-web-desktop - Windows installer.

    Copies the launcher into place and creates the shortcuts that make the
    DeepSeek Harness GUI reachable from the Start Menu, the Desktop, and (once
    you pin it) the taskbar.

    Usage
      .\windows\install.ps1                          install with defaults
      .\windows\install.ps1 -Workspace D:\my\work    working directory for the GUI
      .\windows\install.ps1 -Port 8080               listen on another port
      .\windows\install.ps1 -InstallDir C:\tools\dsh-web-desktop
      .\windows\install.ps1 -NoDesktopShortcut
      .\windows\uninstall.ps1                        remove everything again

    Creates a "DSH Web" shortcut (desktop + Start menu) that starts the server,
    and a "DSH Web (Stop)" one. Clicking "DSH Web" while the server is already
    running asks whether to restart it or open another window, so restarting
    never needs a command line.

    Every string here is ASCII on purpose: Windows PowerShell 5.1 reads
    BOM-less .ps1 files as ANSI, so non-ASCII text would corrupt on machines
    whose code page differs.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$Workspace,
    [int]$Port = 3080,
    [switch]$NoDesktopShortcut,
    [switch]$NoStartMenuShortcut,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { if (-not $Quiet) { Write-Host $Message } }

# ---- resolve the folders, through the OS API: a sanitized or elevated process
# ---- may have no USERPROFILE/APPDATA in its environment.
$userProfile = [Environment]::GetFolderPath('UserProfile')
if (-not $userProfile) { $userProfile = $env:USERPROFILE }
if (-not $userProfile) { $userProfile = $HOME }
if (-not $userProfile) { throw 'cannot resolve the user profile directory' }

$sourceRoot = Split-Path -Parent $PSScriptRoot
$sourceWindows = Join-Path $sourceRoot 'windows'
$sourceAssets = Join-Path $sourceRoot 'assets'

if (-not $InstallDir) { $InstallDir = Join-Path $userProfile '.dsh\launchers' }
if (-not $Workspace) { $Workspace = $userProfile }

$appData = [Environment]::GetFolderPath('ApplicationData')
$startMenu = [Environment]::GetFolderPath('Programs')
$desktop = [Environment]::GetFolderPath('Desktop')
$systemDir = [Environment]::SystemDirectory
$psExe = Join-Path $systemDir 'WindowsPowerShell\v1.0\powershell.exe'

foreach ($pair in @(
    @('launcher source', (Join-Path $sourceWindows 'dsh-web.ps1')),
    @('icon source', (Join-Path $sourceAssets 'dsh-web.ico')),
    @('logo source', (Join-Path $sourceAssets 'dsh-web.png')),
    @('powershell.exe', $psExe)
)) {
    if (-not (Test-Path $pair[1])) { throw "missing $($pair[0]): $($pair[1])" }
}

Write-Step 'dsh-web-desktop installer'
Write-Step ''
Write-Step ("  install dir : {0}" -f $InstallDir)
Write-Step ("  workspace   : {0}" -f $Workspace)
Write-Step ("  port        : {0}" -f $Port)
Write-Step ("  start menu  : {0}" -f $(if ($NoStartMenuShortcut) { 'skipped' } else { $startMenu }))
Write-Step ("  desktop     : {0}" -f $(if ($NoDesktopShortcut) { 'skipped' } else { $desktop }))
Write-Step ''

# ---- payload -----------------------------------------------------------------
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$payload = @(
    @((Join-Path $sourceWindows 'dsh-web.ps1'), 'dsh-web.ps1'),
    @((Join-Path $sourceAssets 'dsh-web.ico'), 'dsh-web.ico'),
    @((Join-Path $sourceAssets 'dsh-web.png'), 'dsh-web.png')
)
foreach ($entry in $payload) {
    Copy-Item $entry[0] (Join-Path $InstallDir $entry[1]) -Force
    Write-Step ("  copied {0}" -f $entry[1])
}

$launcher = Join-Path $InstallDir 'dsh-web.ps1'
$icon = Join-Path $InstallDir 'dsh-web.ico'

# Record how this install was configured. The uninstaller stops the server on
# THIS port; without the record it would fall back to 3080 and could stop an
# unrelated dsh instance that happens to listen there.
$settings = [pscustomobject]@{
    port        = $Port
    workspace   = $Workspace
    installedAt = (Get-Date).ToString('s')
} | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $InstallDir 'install.json'), $settings, (New-Object System.Text.UTF8Encoding($false)))
Write-Step '  wrote install.json'

# ---- shortcuts ---------------------------------------------------------------
$shell = New-Object -ComObject WScript.Shell
$created = @()

function New-LauncherShortcut {
    param([string]$Path, [string]$ExtraArgs, [string]$Description)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Port {1} -Workspace "{2}"' -f $launcher, $Port, $Workspace
    if ($ExtraArgs) { $arguments = "$arguments $ExtraArgs" }
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $psExe
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $Workspace
    $shortcut.IconLocation = "$icon,0"
    $shortcut.Description = $Description
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    $script:created += $Path
    Write-Step ("  shortcut {0}" -f $Path)
}

if (-not $NoStartMenuShortcut) {
    New-LauncherShortcut -Path (Join-Path $startMenu 'DSH Web.lnk') -ExtraArgs '' -Description 'Open the DeepSeek Harness web GUI'
    New-LauncherShortcut -Path (Join-Path $startMenu 'DSH Web (Stop).lnk') -ExtraArgs '-Stop' -Description 'Stop the DeepSeek Harness web GUI'
}
if (-not $NoDesktopShortcut) {
    New-LauncherShortcut -Path (Join-Path $desktop 'DSH Web.lnk') -ExtraArgs '' -Description 'Open the DeepSeek Harness web GUI'
}

# One icon, one decision. An earlier version shipped a separate "DSH Web
# (Restart)" shortcut, and a second entry that does something the first one
# already offers only makes people choose before they know the difference.
# Remove it so re-running the installer cannot leave both behind.
$legacy = @(
    (Join-Path $desktop 'DSH Web (Restart).lnk'),
    (Join-Path $startMenu 'DSH Web (Restart).lnk')
)
foreach ($old in $legacy) {
    if ($old -and (Test-Path $old)) {
        Remove-Item $old -Force
        Write-Step ("  removed obsolete shortcut {0}" -f $old)
    }
}

# ---- smoke test --------------------------------------------------------------
Write-Step ''
Write-Step '  checking the installed launcher ...'
try {
    $check = & $psExe -NoProfile -ExecutionPolicy Bypass -File $launcher -Check -Quiet 2>&1
    foreach ($line in $check) { Write-Step ("    {0}" -f $line) }
} catch {
    Write-Step ("    check failed: {0}" -f $_.Exception.Message)
}

# ---- what is left for the user ----------------------------------------------
Write-Step ''
Write-Step 'Done. Three things the installer cannot do for you:'
Write-Step ''
Write-Step '  1. Pin it to the taskbar. Windows 11 has no supported way for a script'
Write-Step '     to pin an item, so do it once by hand:'
Write-Step '       Start menu -> search "DSH Web" -> right click -> More -> Pin to taskbar'
Write-Step '     (or drag the desktop shortcut onto the taskbar).'
Write-Step '  2. Click "DSH Web" while the server is already running and it asks'
Write-Step '     whether to restart it or open another window. Choose Restart after'
Write-Step '     changing a plugin; the server must reload for the change to apply.'
Write-Step '  3. If you want `dsh web` itself to open the Chrome app window - not just'
Write-Step '     the shortcuts - install the plugin part as well:'
Write-Step '       npm i -g pnpm          # once, only if pnpm is missing'
Write-Step '       dsh plugin --profile web add <this-repo-or-package>'
Write-Step ''
