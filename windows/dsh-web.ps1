<#
    dsh-web-desktop launcher (Windows).

      dsh-web.ps1                 start dsh web in the background, then open the GUI
      dsh-web.ps1 -Stop           stop the dsh web server listening on the port
      dsh-web.ps1 -Check          print diagnostics only, change nothing

    Started by the shortcuts this project installs. Logs live in .\logs next to
    this file. The GUI opens as a Chrome app window: no address bar, its own
    taskbar button, and the DeepSeek Harness icon on it.

    Every string in this file is ASCII on purpose: Windows PowerShell 5.1 reads
    BOM-less .ps1 files as ANSI, so non-ASCII text here would corrupt for anyone
    whose code page differs.
#>
[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Check,
    [switch]$NoBrowser,
    [switch]$NoAppMode,
    [switch]$Quiet,
    [string]$Browser = 'chrome',
    [int]$Port = 0,
    [string]$Workspace = ''
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir = Join-Path $Root 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'dsh-web.log'
$OutFile = Join-Path $LogDir 'dsh-web.out.log'
$ErrFile = Join-Path $LogDir 'dsh-web.err.log'
$UrlFile = Join-Path $LogDir 'current-url.txt'

# The installer records the port and workspace it was configured with, so a
# bare invocation - the uninstaller, or someone running the script by hand -
# behaves exactly like the shortcuts do. Explicit parameters still win.
$settingsPath = Join-Path $Root 'install.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($Port -le 0 -and $settings.port) { $Port = [int]$settings.port }
        if (-not $Workspace -and $settings.workspace) { $Workspace = [string]$settings.workspace }
    } catch { }
}
if ($Port -le 0) { $Port = 3080 }
if (-not $Workspace) { $Workspace = $env:USERPROFILE }
$Url = "http://127.0.0.1:$Port/"

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Show-Message([string]$Text, [string]$Title = 'DSH Web', [int]$Icon = 64, [int]$Seconds = 20) {
    # Called from the installer/uninstaller there is a console to write to and
    # nobody to click a dialog, so -Quiet turns the popup into plain output.
    if ($Quiet) { Write-Output $Text; return }
    # The popup is modal: give it a deadline so a click can never leave the
    # launcher (and a following click) hanging on a dialog nobody dismissed.
    try { (New-Object -ComObject WScript.Shell).Popup($Text, $Seconds, $Title, $Icon) | Out-Null } catch { }
}

# --- startup splash ----------------------------------------------------------
# A small topmost card shown only when booting takes long enough to need
# feedback; it closes itself once the URL has been handed to the browser.
$script:Splash = $null
$SplashDelaySeconds = 2

function Initialize-Splash {
    $script:Splash = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        if (-not ('DshSplashForm' -as [type])) {
            # WinForms gives no property for these two: without them the card
            # would steal focus from whatever the user is typing in, and would
            # add a taskbar button of its own.
            Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
using System.Windows.Forms;
public class DshSplashForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            return cp;
        }
    }
}
'@
        }
        try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

        $width = 384
        $height = 136
        $form = New-Object DshSplashForm
        $form.Text = 'DSH Web'
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.ClientSize = New-Object System.Drawing.Size -ArgumentList $width, $height
        $form.BackColor = [System.Drawing.Color]::FromArgb(23, 26, 36)

        $region = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = 16
        $region.AddArc(0, 0, $r, $r, 180, 90)
        $region.AddArc($width - $r, 0, $r, $r, 270, 90)
        $region.AddArc($width - $r, $height - $r, $r, $r, 0, 90)
        $region.AddArc(0, $height - $r, $r, $r, 90, 90)
        $region.CloseFigure()
        $form.Region = New-Object System.Drawing.Region -ArgumentList $region

        $font = 'Segoe UI'
        $logo = Join-Path $Root 'dsh-web.png'
        if (Test-Path $logo) {
            $picture = New-Object System.Windows.Forms.PictureBox
            $picture.Image = [System.Drawing.Image]::FromFile($logo)
            $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
            $picture.Location = New-Object System.Drawing.Point -ArgumentList 26, 40
            $picture.Size = New-Object System.Drawing.Size -ArgumentList 58, 58
            $form.Controls.Add($picture)
            $picture.BackColor = [System.Drawing.Color]::Transparent
        }

        $title = New-Object System.Windows.Forms.Label
        $title.Text = 'DeepSeek Harness'
        $title.Font = New-Object System.Drawing.Font -ArgumentList $font, 13, ([System.Drawing.FontStyle]::Bold)
        $title.ForeColor = [System.Drawing.Color]::White
        $title.AutoSize = $true
        $title.Location = New-Object System.Drawing.Point -ArgumentList 104, 30
        $form.Controls.Add($title)
        $title.BackColor = [System.Drawing.Color]::Transparent

        $status = New-Object System.Windows.Forms.Label
        $status.Text = 'Starting the server ...'
        $status.Font = New-Object System.Drawing.Font -ArgumentList $font, 9
        $status.ForeColor = [System.Drawing.Color]::FromArgb(166, 176, 202)
        $status.AutoSize = $true
        $status.Location = New-Object System.Drawing.Point -ArgumentList 106, 62
        $form.Controls.Add($status)
        $status.BackColor = [System.Drawing.Color]::Transparent

        # A self-drawn runner instead of a ProgressBar: the themed control is a
        # chunky green block that fights the dark card, and its own animation
        # would need a real message pump anyway.
        $track = New-Object System.Windows.Forms.Panel
        $track.Size = New-Object System.Drawing.Size -ArgumentList 254, 4
        $track.Location = New-Object System.Drawing.Point -ArgumentList 106, 94
        $track.BackColor = [System.Drawing.Color]::FromArgb(43, 49, 69)
        $form.Controls.Add($track)

        $runner = New-Object System.Windows.Forms.Panel
        $runner.Size = New-Object System.Drawing.Size -ArgumentList 64, 4
        $runner.Location = New-Object System.Drawing.Point -ArgumentList -64, 0
        $runner.BackColor = [System.Drawing.Color]::FromArgb(111, 155, 255)
        $track.Controls.Add($runner)

        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $script:Splash = [pscustomobject]@{
            Form = $form; Status = $status; Track = $track; Runner = $runner; Started = (Get-Date)
        }
    } catch {
        Write-Log "splash: unavailable ($($_.Exception.Message))"
        $script:Splash = $null
    }
}

function Update-Splash([string]$Text) {
    if (-not $script:Splash) { return }
    try {
        $splash = $script:Splash
        $splash.Status.Text = $Text
        # Travel one track-length every ~1.8s, wrapping around the right edge.
        $span = $splash.Track.Width + $splash.Runner.Width
        $phase = ((Get-Date) - $splash.Started).TotalSeconds * ($span / 1.8)
        $splash.Runner.Left = [int]($phase % $span) - $splash.Runner.Width
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

# Sleep that keeps the card painting and the runner moving.
function Wait-Pumping([int]$Milliseconds) {
    $end = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $end) {
        if ($script:Splash) { Update-Splash $script:Splash.Status.Text }
        Start-Sleep -Milliseconds 15
    }
}

function Close-Splash {
    if (-not $script:Splash) { return }
    try {
        $script:Splash.Form.Close()
        $script:Splash.Form.Dispose()
    } catch { }
    $script:Splash = $null
}

function Test-PortOpen([int]$P) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $P, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(500, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-PortOwner([int]$P) {
    $pattern = '^\s+TCP\s+\S+:{0}\s+\S+\s+LISTENING\s+(\d+)' -f $P
    $match = netstat -ano | Select-String -Pattern $pattern | Select-Object -First 1
    if ($match) { return [int]$match.Matches[0].Groups[1].Value }
    return 0
}

# Finds the dsh CLI entry without assuming where it was installed: the command
# on PATH first, then the npm global root, then a couple of common layouts.
function Resolve-Dsh {
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('dsh.cmd', 'dsh')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $dirs.Add((Split-Path -Parent $cmd.Source)) }
    }
    $nodeCmd = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    $node = $null
    if ($nodeCmd) { $node = $nodeCmd.Source }
    if ($node) {
        $nodeDir = Split-Path -Parent $node
        $dirs.Add($nodeDir)
        try {
            $globalRoot = (& $node -e "process.stdout.write(require('path').join(process.execPath,'..'))" 2>$null)
            if ($globalRoot) { $dirs.Add($globalRoot) }
        } catch { }
    }
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ($appData) { $dirs.Add((Join-Path $appData 'npm')) }
    $dirs.Add('C:\Program Files\nodejs')
    foreach ($dir in $dirs) {
        $bin = Join-Path $dir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
        if (Test-Path $bin) {
            if (-not $node) { $node = 'node' }
            return [pscustomobject]@{ Node = $node; Bin = $bin; Dir = $dir }
        }
    }
    return $null
}

# Chrome only by design: the app window (own taskbar button, own icon) is a
# Chromium feature, and Chrome is what this project targets.
function Resolve-Browser([string]$Preference) {
    if ($Preference -and $Preference -ne 'chrome' -and (Test-Path $Preference)) { return $Preference }
    $cmd = Get-Command 'chrome.exe' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $candidates = @()
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ($local) { $candidates += (Join-Path $local 'Google\Chrome\Application\chrome.exe') }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) { $candidates += (Join-Path $base 'Google\Chrome\Application\chrome.exe') }
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

function Get-LogTail([string]$Path, [int]$Lines = 12) {
    if (-not (Test-Path $Path)) { return '' }
    $text = Get-Content -Path $Path -Tail $Lines -ErrorAction SilentlyContinue
    if (-not $text) { return '' }
    # Never surface the process token URL in a dialog.
    return (($text -join "`r`n") -replace 'token=[^\s&]+', 'token=***')
}

$dsh = Resolve-Dsh
$browser = $null
if (-not $NoAppMode) { $browser = Resolve-Browser $Browser }
$owner = Get-PortOwner $Port
$running = $owner -gt 0
if ($running -and -not (Test-PortOpen $Port)) { $running = $false }

# Opens the GUI. With Chrome this is an app window: no address bar, and Windows
# gives it its own taskbar button carrying the DeepSeek Harness icon.
function Open-Gui([string]$Target) {
    if ($NoBrowser) { return }
    if ($browser) {
        Write-Log "open: $browser --app=$Target"
        try { Start-Process -FilePath $browser -ArgumentList "--app=$Target" }
        catch { Write-Log "open: app window failed: $($_.Exception.Message)"; Start-Process $Target }
    } else {
        Write-Log "open: default browser $Target"
        Start-Process $Target
    }
}

if ($Check) {
    Write-Output "port        : $Port (listening: $running, owner PID: $owner)"
    Write-Output "dsh node    : $(if ($dsh) { $dsh.Node } else { '<not found>' })"
    Write-Output "dsh entry   : $(if ($dsh) { $dsh.Bin } else { '<not found>' })"
    Write-Output "browser     : $(if ($browser) { $browser } else { '<none: falls back to the default browser>' })"
    Write-Output "workspace   : $Workspace (exists: $(Test-Path $Workspace))"
    Write-Output "logs        : $LogDir"
    exit 0
}

# --- stop --------------------------------------------------------------------
if ($Stop) {
    if (-not $running) { Show-Message "DSH Web is not running (nothing is listening on port $Port)." 'DSH Web' 64 8; exit 0 }
    $proc = Get-Process -Id $owner -ErrorAction SilentlyContinue
    if (-not $proc) { Show-Message "Could not find the process holding port $Port (PID $owner)." 'DSH Web' 48 20; exit 1 }
    # Never kill a stranger: only a node process may be the dsh server, and the
    # port might belong to something else entirely.
    if ($proc.ProcessName -ne 'node') {
        Write-Log "stop: refused - port $Port is held by $($proc.ProcessName) (PID $owner), not node"
        Show-Message "Port $Port is held by '$($proc.ProcessName)' (PID $owner), which is not a dsh server.`r`n`r`nNot stopping it." 'DSH Web' 48 25
        exit 1
    }
    Write-Log "stop: killing PID $owner ($($proc.ProcessName))"
    Stop-Process -Id $owner -Force
    Start-Sleep -Milliseconds 1000
    if (Test-PortOpen $Port) {
        Show-Message "Port $Port is still in use - end PID $owner in Task Manager." 'DSH Web' 48 30
        exit 1
    }
    Write-Log 'stop: done'
    exit 0
}

# --- start -------------------------------------------------------------------
if ($running) {
    # A server is already serving this port. Confirm it is dsh (it answers 401
    # without a browser cookie) and reuse it instead of failing to bind.
    # dsh answers 401 (and 403 on a rejected Host) without a browser cookie;
    # anything else on this port belongs to a different program.
    $isDsh = $false
    try {
        $response = Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 5
        Write-Log "reuse: port $Port answered $([int]$response.StatusCode); not a dsh server"
    } catch {
        $response = $_.Exception.Response
        if ($response) {
            $code = [int]$response.StatusCode
            if ($code -eq 401 -or $code -eq 403) { $isDsh = $true }
            else { Write-Log "reuse: port $Port answered $code; not a dsh server" }
        } else {
            Write-Log "reuse: port $Port probe failed: $($_.Exception.Message)"
        }
    }
    if (-not $isDsh) {
        Write-Log "reuse: port $Port is taken by another program (PID $owner)"
        Show-Message "Port $Port is already used by another program (PID $owner), so DSH Web cannot start.`r`n`r`nClose that program, or start this launcher with another -Port." 'DSH Web' 16 45
        exit 1
    }
    # Prefer the token URL recorded by the last launch: it authenticates even a
    # browser that has no cookie for this server yet.
    $target = $Url
    if (Test-Path $UrlFile) {
        $stored = (Get-Content $UrlFile -Raw).Trim()
        if ($stored -match "^http://127\.0\.0\.1:$Port/\?token=\S+$") { $target = $stored }
    }
    Write-Log "reuse: port $Port already serving (PID $owner); opening $target"
    Open-Gui $target
    exit 0
}

if (-not $dsh) {
    Write-Log 'error: dsh entry not found'
    Show-Message "Could not find the dsh CLI.`r`n`r`nInstall it first (npm i -g @deepseek-ai/dsh) or point this launcher at it." 'DSH Web' 16 45
    exit 1
}
if (-not (Test-Path $Workspace)) {
    Write-Log "warn: workspace '$Workspace' missing; falling back to $Root"
    $Workspace = $Root
}

$startArgs = @($dsh.Bin, 'web', '--port', "$Port")
# With an app-mode browser we open the window ourselves, so dsh must not also
# dump the URL into the default browser.
if ($NoBrowser -or $browser) { $startArgs += '--no-open' }
Write-Log "start: $($dsh.Node) $($startArgs -join ' ') (cwd $Workspace)"
Remove-Item $OutFile, $ErrFile -ErrorAction SilentlyContinue

try {
    $process = Start-Process -FilePath $dsh.Node `
        -ArgumentList $startArgs `
        -WorkingDirectory $Workspace `
        -WindowStyle Hidden `
        -RedirectStandardOutput $OutFile `
        -RedirectStandardError $ErrFile `
        -PassThru
} catch {
    Write-Log "error: could not start dsh: $($_.Exception.Message)"
    Close-Splash
    Show-Message "Starting dsh web failed:`r`n$($_.Exception.Message)" 'DSH Web' 16 45
    exit 1
}

$startedAt = Get-Date
$deadline = $startedAt.AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    $waited = [int]((Get-Date) - $startedAt).TotalSeconds
    if (-not $script:Splash -and $waited -ge $SplashDelaySeconds) { Initialize-Splash }
    Update-Splash "Starting the server ... ${waited}s"
    if (Test-PortOpen $Port) { break }
    if ($process.HasExited) { break }
    Wait-Pumping 500
}

if (Test-PortOpen $Port) {
    # The URL line is printed once the loader tree settles, a moment after the
    # bind; wait for it and keep it for later reuse clicks.
    $handoffUrl = ''
    $urlDeadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $urlDeadline -and -not $handoffUrl) {
        $waited = [int]((Get-Date) - $startedAt).TotalSeconds
        Update-Splash "Waiting for the interface ... ${waited}s"
        if (Test-Path $OutFile) {
            try {
                $found = Select-String -Path $OutFile -Pattern 'dsh web:\s+(\S+)' -ErrorAction Stop | Select-Object -First 1
                if ($found) { $handoffUrl = $found.Matches[0].Groups[1].Value }
            } catch { }
        }
        if (-not $handoffUrl) { Wait-Pumping 400 }
    }
    if ($handoffUrl) {
        try { Set-Content -Path $UrlFile -Value $handoffUrl -Encoding ASCII } catch { }
        Write-Log "start: ready on $handoffUrl (PID $($process.Id))"
    } else {
        Write-Log "start: ready on $Url (PID $($process.Id)); the authenticated URL line never appeared"
    }
    Update-Splash 'Opening the browser ...'
    if (-not $NoBrowser) {
        $openTarget = $Url
        if ($handoffUrl) { $openTarget = $handoffUrl }
        if ($browser) {
            Open-Gui $openTarget
        } else {
            # dsh handed the URL to the default browser itself; only step in if
            # it reports that the handoff failed.
            Wait-Pumping 2000
            $errText = ''
            if (Test-Path $ErrFile) { $errText = Get-Content $ErrFile -Raw }
            if ($errText -match 'could not open the default browser') {
                Write-Log 'start: browser handoff failed; opening the URL directly'
                Open-Gui $openTarget
            }
        }
    }
    Wait-Pumping 900
    Close-Splash
    exit 0
}

Close-Splash
$tail = @(Get-LogTail $ErrFile) + @(Get-LogTail $OutFile) | Where-Object { $_ }
$message = "dsh web did not become ready on port $Port.`r`n`r`n" + ($tail -join "`r`n")
if (-not $tail) { $message += "No output at all - see $LogDir." }
Write-Log "error: not ready; exited=$($process.HasExited) code=$($process.ExitCode)"
Show-Message $message 'DSH Web' 16 60
exit 1
