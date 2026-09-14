<#
    dsh-web-desktop launcher (Windows).

      dsh-web.ps1                 start dsh web, then open the GUI
      dsh-web.ps1 -Restart        stop the running server first, then start it again
      dsh-web.ps1 -New            leave the running server alone, open another window
      dsh-web.ps1 -Stop           stop the dsh web server listening on the port
      dsh-web.ps1 -Check          print diagnostics only, change nothing

    When a server is already listening, the bare invocation asks what to do -
    restart it, or open another window - because those are the only two things a
    second click can sensibly mean, and a desktop icon has no arguments to say
    which one was wanted. -Restart, -New and -NoPrompt answer it in advance.

    Started by the shortcuts this project installs. Logs live in .\logs next to
    this file. The GUI opens as a Chrome app window: no address bar, its own
    taskbar button, and the DeepSeek Harness icon on it.

    Every string in this file must stay ASCII: the shortcuts run powershell.exe
    (Windows PowerShell 5.1), which reads a BOM-less .ps1 as ANSI, and the
    installer writes this file back with a BOM-less UTF8 encoding - so non-ASCII
    text here would corrupt on any machine whose code page differs. That is why
    the dialogs below are English, including the wording of the two-button
    choice.
#>
[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Restart,
    [switch]$New,
    [switch]$NoPrompt,
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

# The launcher normally runs hidden, so an uncaught error looks to the user like
# a window that flashed and vanished. Write it down before dying: without this
# there is nothing at all to diagnose from.
trap {
    $detail = "$($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
    try { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') unhandled: $detail" -Encoding UTF8 } catch { }
    exit 1
}

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

# Shows the choice card and returns the C# answer code: 1 restart, 2 open,
# 0 cancel. The only place that builds the dialog.
function Ask-ChoiceCard([int]$Port) {
    Initialize-CardTypes
    $owner = $null
    if ($script:Splash -and $script:Splash.Form) { $owner = $script:Splash.Form }
    $dialog = New-Object DshChoiceCard
    if ($owner) { $dialog.Owner = $owner }
    try {
        return [int]$dialog.Ask()
    } finally {
        $dialog.Dispose()
    }
}
# The choice card asks a different question than a plain message box: a second
# click on the icon either restarts the server or opens another window, and
# nothing about the icon says which. Yes is the default because a repeat click
# usually follows a plugin change.
function Ask-Action([int]$Port) {
    if ($Quiet) { return 'open' }              # installer/uninstaller: never prompt
    if ($Restart) { return 'restart' }
    if ($New) { return 'open' }
    if ($NoPrompt) { return 'open' }
    switch (Ask-ChoiceCard $Port) {
        1 { return 'restart' }
        2 { return 'open' }
        default { return 'cancel' }
    }
}

# --- shared WinForms card source --------------------------------------------
# The splash card and the choice dialog are compiled from this one string: an
# earlier revision pasted the whole thing into both call sites, and the copies
# silently drifted apart. Kept as a single-quoted here-string (no interpolation
# of the C# below) and compiled whenever either entry point needs it.
$script:CardSource = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
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

// The whole progress card is drawn by this one control, and animated by its own
// timer, so the runner sweeps at display rate. It must not depend on PowerShell
// pumping messages: a launcher that is busy probing a TCP port or waiting on a
// process cannot paint often enough, and a slider that only moves when the
// script gets around to it looks like it stalls once a second.
public class DshWaitCard : Control {
    private readonly Timer tick = new Timer();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly string[] shimmer = new string[] { ".", "..", "..." };
    private string line1 = "";
    private string line2 = "";
    private string headline = "DeepSeek Harness";
    private int shimmerStep;

    // The product name is the default headline; the choice dialog reuses the
    // same card for its own question, so it has to be settable.
    public string Headline {
        get { return headline; }
        set { headline = value == null ? "" : value; Invalidate(); }
    }

    public DshWaitCard() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
               | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque
               | ControlStyles.ResizeRedraw, true);
        tick.Interval = 16; // ~60 fps
        tick.Tick += delegate { shimmerStep++; Invalidate(); };
        tick.Start();
    }

    // line1 is the steady headline; line2 changes rarely (the elapsed seconds),
    // so repaints stay cheap.
    public void SetText(string first, string second) {
        if (first == null) first = "";
        if (second == null) second = "";
        if (first == line1 && second == line2) return;
        line1 = first;
        line2 = second;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(this.BackColor);

        // The logo is a child control parked at x=28..86, so every string starts
        // to the right of it: the previous revision drew the headline from x=26
        // and the icon sat on top of the "De".
        int left = 100;
        int right = 28;

        using (SolidBrush fg = new SolidBrush(Color.White))
        using (SolidBrush dim = new SolidBrush(Color.FromArgb(166, 176, 202)))
        using (Font bold = new Font("Segoe UI", 13f, FontStyle.Bold))
        using (Font small = new Font("Segoe UI", 9f)) {
            g.DrawString(headline, bold, fg, left, 32);
            g.DrawString(line1 + shimmer[shimmerStep % 3], small, dim, left + 1, 66);
        }

        int trackY = 96;
        int trackH = 5;
        int trackX = left;
        int trackW = this.ClientSize.Width - trackX - right;
        if (trackW < 32) trackW = 32;
        using (GraphicsPath track = Rounded(new RectangleF(trackX, trackY, trackW, trackH), trackH / 2f))
        using (SolidBrush trackBrush = new SolidBrush(Color.FromArgb(43, 49, 69)))
        using (Pen trackEdge = new Pen(Color.FromArgb(60, 68, 94))) {
            g.FillPath(trackBrush, track);
            g.DrawPath(trackEdge, track);
        }

        int runnerW = 92;
        if (runnerW > trackW) runnerW = trackW;
        // Ping-pong the runner instead of wrapping it: the smoothstep easing
        // eases in and out at both edges, so there is no visible jump when it
        // turns around. One sweep takes 1.5s.
        double phase = (clock.Elapsed.TotalSeconds % 1.5) / 1.5;
        double eased = phase < 0.5 ? 2 * phase * phase : 1 - 2 * (1 - phase) * (1 - phase);
        RectangleF runnerRect = new RectangleF(
            trackX + (float)(eased * (trackW - runnerW)), trackY, runnerW, trackH);
        // A soft halo wider than the bar, drawn first: it reads as motion at a
        // glance even when a single frame is on screen.
        using (GraphicsPath halo = Rounded(new RectangleF(runnerRect.X - 5, trackY - 4, runnerW + 10, trackH + 8), (trackH + 8) / 2f))
        using (SolidBrush haloBrush = new SolidBrush(Color.FromArgb(34, 111, 155, 255))) {
            g.FillPath(haloBrush, halo);
        }
        using (GraphicsPath runner = Rounded(runnerRect, trackH / 2f))
        using (LinearGradientBrush runnerBrush = new LinearGradientBrush(
                   new RectangleF(runnerRect.X, trackY, runnerW, trackH),
                   Color.FromArgb(126, 168, 255), Color.FromArgb(86, 126, 240), 0f)) {
            g.FillPath(runnerBrush, runner);
        }

        if (line2.Length > 0) {
            using (SolidBrush dim2 = new SolidBrush(Color.FromArgb(112, 124, 152)))
            using (Font tiny = new Font("Segoe UI", 8f)) {
                SizeF size = g.MeasureString(line2, tiny);
                g.DrawString(line2, tiny, dim2, this.ClientSize.Width - right - size.Width, trackY + 10);
            }
        }
    }

    private static GraphicsPath Rounded(RectangleF r, float radius) {
        GraphicsPath path = new GraphicsPath();
        if (radius < 0.5f) { path.AddRectangle(r); return path; }
        float d = radius * 2f;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing) {
        if (disposing) { tick.Stop(); tick.Dispose(); }
        base.Dispose(disposing);
    }
}
// The choice card. WScript.Shell.Popup would be shorter, but it renders only a
// single OK button on some systems regardless of the requested button set, and
// it always draws the stock grey message box. This one is a real dark modal
// with three buttons whose captions and order are ours.
public class DshChoiceCard : DshSplashForm {
    public const int Restart = 1;
    public const int Open = 2;
    public const int Cancel = 0;

    public int Choice = Cancel;

    private readonly Label status = new Label();
    private readonly Timer poll = new Timer();

    // No formal parameter for the owner: PowerShell's New-Object cannot match a
    // constructor that takes an interface when the argument is $null, so the
    // card is built first and the owner assigned afterwards.
    public DshChoiceCard() {
        Text = "DSH Web";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        ShowInTaskbar = true;
        ClientSize = new Size(468, 200);
        BackColor = Color.FromArgb(23, 26, 36);
        KeyPreview = true;

        // Text is drawn straight onto the form: the splash-style card brought a
        // progress bar along with it, and a bar in a question dialog implies the
        // dialog is working on something when it is only waiting to be answered.
        Label title = MakeLabel("DeepSeek Harness", 12f, FontStyle.Bold, Color.White, 28, 22);
        Controls.Add(title);
        Label question = MakeLabel("Restart the server, or open another window?", 10f, FontStyle.Regular,
            Color.FromArgb(226, 232, 246), 28, 60);
        Controls.Add(question);
        Label hint = MakeLabel("Restart closes the running server first, then starts it again.", 9f,
            FontStyle.Regular, Color.FromArgb(140, 152, 180), 28, 84);
        Controls.Add(hint);

        // Below the buttons and added last: drawn across the whole width it used
        // to sit under them and was partly hidden by the middle button.
        status.Font = new Font("Segoe UI", 9f);
        status.ForeColor = Color.FromArgb(140, 152, 180);
        status.BackColor = Color.Transparent;
        status.AutoSize = false;
        status.TextAlign = ContentAlignment.MiddleCenter;
        status.Location = new Point(0, 164);
        status.Size = new Size(468, 20);
        Controls.Add(status);

        Button restart = MakeButton("Restart server", 28, 116, 138);
        restart.BackColor = Color.FromArgb(111, 155, 255);
        restart.ForeColor = Color.FromArgb(16, 20, 32);
        restart.Click += delegate { Answer(Restart); };
        Controls.Add(restart);

        Button open = MakeButton("New window", 174, 116, 128);
        open.BackColor = Color.FromArgb(43, 49, 69);
        open.ForeColor = Color.FromArgb(226, 232, 246);
        open.Click += delegate { Answer(Open); };
        Controls.Add(open);

        Button cancel = MakeButton("Cancel", 310, 116, 100);
        cancel.BackColor = Color.FromArgb(43, 49, 69);
        cancel.ForeColor = Color.FromArgb(166, 176, 202);
        cancel.Click += delegate { Answer(Cancel); };
        Controls.Add(cancel);

        // Restart is the default: a repeat click usually follows a plugin change.
        AcceptButton = restart;
        CancelButton = cancel;

        // The countdown must not depend on the launcher: it is blocked waiting
        // for this dialog, so nothing else would ever decrement it.
        poll.Interval = 500;
        poll.Tick += delegate {
            int tick = 25;
            object tag = status.Tag;
            if (tag is int) tick = (int)tag;
            tick--;
            status.Tag = tick;
            if (tick <= 0) {
                Answer(Cancel);
                return;
            }
            status.Text = "Nothing happens if you do not choose (" + tick + "s)";
        };
    }

    private static Button MakeButton(string caption, int x, int y, int width) {
        Button button = new Button();
        button.Text = caption;
        button.Font = new Font("Segoe UI", 9f);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.Location = new Point(x, y);
        button.Size = new Size(width, 32);
        button.TabStop = true;
        return button;
    }

    private static Label MakeLabel(string caption, float size, FontStyle style, Color colour, int x, int y) {
        Label label = new Label();
        label.Text = caption;
        label.Font = new Font("Segoe UI", size, style);
        label.ForeColor = colour;
        label.BackColor = Color.Transparent;
        label.AutoSize = true;
        label.Location = new Point(x, y);
        return label;
    }

    private void Answer(int choice) {
        Choice = choice;
        poll.Stop();
        Close();
    }

    public int Ask() {
        // Start the countdown before the modal loop takes over; ShowDialog runs
        // its own message loop, so the timer keeps ticking without any help
        // from the launcher (which is blocked right here).
        status.Text = "Nothing happens if you do not choose (25s)";
        status.Tag = 25;
        poll.Start();
        try { DisplayStyle(); } catch { }
        // Owner is unset when there is no splash card to hang this off, in which
        // case ShowDialog still centres the dialog on the screen.
        if (Owner != null) { ShowDialog(Owner); } else { ShowDialog(); }
        poll.Stop();
        return Choice;
    }

    // A dark title bar and rounded corners, asked for by attribute so a build
    // without the API simply keeps the default window chrome.
    private void DisplayStyle() {
        try {
            object wsh = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            string exe = (string)wsh.GetType().InvokeMember("ExpandEnvironmentStrings",
                System.Reflection.BindingFlags.InvokeMethod, null, wsh,
                new object[] { "%SystemRoot%\\System32\\dwmapi.dll" });
            IntPtr dwm = LoadLibrary(exe);
            if (dwm == IntPtr.Zero) return;
            int value = 2;
            IntPtr p = Marshal.AllocHGlobal(4);
            Marshal.WriteInt32(p, value);
            DwmSetWindowAttribute(Handle, 20, p, 4); // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(Handle, 19, p, 4); // ...and its pre-20H1 number
            Marshal.FreeHGlobal(p);
            FreeLibrary(dwm);
        } catch { }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    private static extern IntPtr LoadLibrary(string path);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr module);

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, IntPtr value, int size);

    // The launcher is hidden, so without this a stray click elsewhere would
    // leave the dialog behind other windows and look like a hang.
    protected override void OnActivated(EventArgs e) {
        base.OnActivated(e);
        TopMost = true;
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        // Rounded corners to match the card, once the handle exists.
        try {
            int radius = 16;
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            System.Drawing.Drawing2D.GraphicsPath path = new System.Drawing.Drawing2D.GraphicsPath();
            path.AddArc(0, 0, radius, radius, 180, 90);
            path.AddArc(w - radius, 0, radius, radius, 270, 90);
            path.AddArc(w - radius, h - radius, radius, radius, 0, 90);
            path.AddArc(0, h - radius, radius, radius, 90, 90);
            path.CloseFigure();
            Region = new Region(path);
        } catch { }
    }

    protected override void Dispose(bool disposing) {
        if (disposing) { poll.Stop(); poll.Dispose(); }
        base.Dispose(disposing);
    }
}
// Reports - by creating a file - the first moment a TCP port accepts a
// connection, without blocking the caller.
//
// The launcher's start loop used to call its own blocking probe once per half
// second, and because a closed port does not refuse instantly on Windows each
// call burned the whole timeout: measured at ~520 ms, so the progress card froze
// for about half of every second.
//
// A single background thread does the polling and writes the file itself. It
// must not call back into PowerShell: a callback would run on a thread with no
// runspace, so any scriptblock doing the work would fail silently.
public class DshPortWatcher {
    private readonly int port;
    private readonly string flagPath;
    private volatile bool stopped;

    public DshPortWatcher(int portToWatch, string pathToCreate) {
        port = portToWatch;
        flagPath = pathToCreate;
    }

    public void Start() {
        System.Threading.Thread thread = new System.Threading.Thread(Loop);
        thread.IsBackground = true;
        thread.Start();
    }

    public void Stop() {
        stopped = true;
    }

    private void Loop() {
        while (!stopped) {
            System.Net.Sockets.TcpClient client = new System.Net.Sockets.TcpClient();
            try {
                // A short timeout keeps the retry interval small: an open port
                // connects in about a millisecond.
                System.IAsyncResult pending = client.BeginConnect("127.0.0.1", port, null, null);
                if (pending.AsyncWaitHandle.WaitOne(200, false)) {
                    try {
                        client.EndConnect(pending);
                        if (!stopped) { System.IO.File.WriteAllText(flagPath, "ready"); }
                        return;
                    } catch {
                        // Refused: the server is not listening yet.
                    }
                }
            } catch {
                // Treated the same as a refused connection.
            } finally {
                try { client.Close(); } catch { }
            }
            System.Threading.Thread.Sleep(40);
        }
    }
}
'@

function Initialize-CardTypes {
    # Declaring the classes once per PowerShell session is enough; Add-Type
    # throws if the same type name is compiled twice.
    if ('DshChoiceCard' -as [type]) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $referenced = @('System.Windows.Forms', 'System.Drawing')
    if (-not ('DshSplashForm' -as [type])) {
        Add-Type -ReferencedAssemblies $referenced -TypeDefinition $script:CardSource
    }
    if (-not ('DshChoiceCard' -as [type])) { throw 'the WinForms card types did not compile' }
}

function Initialize-Splash {
    $script:Splash = $null
    try {
        Initialize-CardTypes
        $width = 384
        $height = 150
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

        $logo = Join-Path $Root 'dsh-web.png'
        if (Test-Path $logo) {
            $picture = New-Object System.Windows.Forms.PictureBox
            $picture.Image = [System.Drawing.Image]::FromFile($logo)
            $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
            $picture.Location = New-Object System.Drawing.Point -ArgumentList 28, 34
            $picture.Size = New-Object System.Drawing.Size -ArgumentList 58, 58
            $form.Controls.Add($picture)
            $picture.BackColor = [System.Drawing.Color]::Transparent
        }

        # One control draws every string plus the runner, and animates the runner
        # on its own timer. Separate labels would each repaint on their own
        # schedule and flicker against the moving card.
        $card = New-Object DshWaitCard
        $card.Dock = [System.Windows.Forms.DockStyle]::Fill
        $card.BackColor = [System.Drawing.Color]::FromArgb(23, 26, 36)
        $form.Controls.Add($card)
        $card.SetText('Starting the server', '')

        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        # Detail must exist from the start: Set-Splash assigns it, and a
        # PSCustomObject rejects a property it was not created with. Leaving it
        # out made every Set-Splash call throw, which killed the launcher right
        # after the card appeared and before it stopped anything.
        $script:Splash = [pscustomobject]@{
            Form = $form; Card = $card; Detail = ''; Started = (Get-Date)
        }
    } catch {
        Write-Log "splash: unavailable ($($_.Exception.Message))"
        $script:Splash = $null
    }
}

# The headline is steady; the caption underneath carries the elapsed seconds.
# Both only repaint when their text actually changes, which is what keeps the
# card smooth while the launcher is busy probing the port.
function Set-Splash([string]$Headline, [string]$Detail) {
    if (-not $script:Splash) { return }
    $script:Splash.Detail = $Detail
    try { $script:Splash.Card.SetText($Headline, $Detail) } catch { }
}
# The runner is animated by the control's own timer, so this only has to keep
# WinForms pumping: no DoEvents storm, and no per-slice position arithmetic.
function Wait-Pumping([int]$Milliseconds) {
    $end = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
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
# The process holding the port, or $null when nothing does. Used both to decide
# whether the running server is ours and to report a refusal.
function Get-PortOwnerProcess([int]$P) {
    $holder = Get-PortOwner $P
    if ($holder -le 0) { return $null }
    return Get-Process -Id $holder -ErrorAction SilentlyContinue
}

# Is the thing on the port really a dsh server?
#
# The port owner decides, not the HTTP probe: a dsh server that is busy answers
# no request at all, and treating that timeout as "some other program" made the
# restart give up and refuse to stop the very server it was asked to restart.
#   - owner is not node            -> 'foreign'  (never touch it)
#   - HTTP answers 401 or 403      -> 'dsh'      (dsh without a browser cookie)
#   - HTTP answers anything else   -> 'foreign'  (a node program, but not dsh)
#   - no answer / timed out        -> 'dsh' if the owner is node, else 'foreign'
#
# Returns the verdict plus the owner's process name so callers can say what they
# found without looking it up again.
function Probe-DshServer([int]$P) {
    $proc = Get-PortOwnerProcess $P
    if (-not $proc) { return [pscustomobject]@{ IsDsh = $false; ProcessName = '<none>'; Detail = 'no process holds the port' } }
    $name = $proc.ProcessName
    if ($name -ne 'node') {
        return [pscustomobject]@{ IsDsh = $false; ProcessName = $name; Detail = "held by $name, not node" }
    }
    $status = 0
    $note = ''
    try {
        $response = Invoke-WebRequest "http://127.0.0.1:$P/" -UseBasicParsing -TimeoutSec 5
        $status = [int]$response.StatusCode
        $note = "answered $status"
    } catch {
        $response = $_.Exception.Response
        if ($response) {
            $status = [int]$response.StatusCode
            $note = "answered $status"
        } else {
            $note = "no answer ($($_.Exception.Message))"
        }
    }
    if ($status -eq 401 -or $status -eq 403) { return [pscustomobject]@{ IsDsh = $true; ProcessName = $name; Detail = $note } }
    if ($status -gt 0) { return [pscustomobject]@{ IsDsh = $false; ProcessName = $name; Detail = $note } }
    # A node process that did not answer is the dsh server under load: still ours.
    return [pscustomobject]@{ IsDsh = $true; ProcessName = $name; Detail = "$note; owner is node" }
}

# Stops the dsh server listening on $Port, and waits for the port to actually
# come free before returning. Returns 'stopped', 'notrunning' or 'blocked'.
function Stop-DshServer {
    if (-not (Test-PortOpen $Port)) { return 'notrunning' }
    $holder = Get-PortOwner $Port
    if ($holder -le 0) { return 'notrunning' }
    $proc = Get-Process -Id $holder -ErrorAction SilentlyContinue
    if (-not $proc) { return 'blocked' }
    # Never kill a stranger: only a node process may be the dsh server, and the
    # port might belong to something else entirely.
    if ($proc.ProcessName -ne 'node') {
        Write-Log "stop: refused - port $Port is held by $($proc.ProcessName) (PID $holder), not node"
        return 'blocked'
    }
    Write-Log "stop: killing PID $holder ($($proc.ProcessName))"
    try { Stop-Process -Id $holder -Force } catch {
        Write-Log "stop: Stop-Process failed: $($_.Exception.Message)"
    }
    # Wait for the socket to close instead of guessing with a fixed sleep: on a
    # restart the new server cannot bind until the old one has let go.
    for ($i = 0; $i -lt 100; $i++) {
        if (-not (Test-PortOpen $Port)) { break }
        Set-Splash 'Stopping the running server' ''
        Start-Sleep -Milliseconds 100
    }
    if (Test-PortOpen $Port) {
        Write-Log "stop: port $Port still listening after killing PID $holder"
        return 'blocked'
    }
    Write-Log 'stop: done'
    return 'stopped'
}

if ($Stop) {
    if (-not $running) { Show-Message "DSH Web is not running (nothing is listening on port $Port)." 'DSH Web' 64 8; exit 0 }
    switch (Stop-DshServer) {
        'stopped' { exit 0 }
        'notrunning' { Show-Message "DSH Web is not running (nothing is listening on port $Port)." 'DSH Web' 64 8; exit 0 }
        default {
            Show-Message "Port $Port is held by a process that is not a dsh server (PID $owner).`r`n`r`nNot stopping it." 'DSH Web' 48 25
            exit 1
        }
    }
}

# --- already running: restart, or open another window? -----------------------
# A server is on the port. Restarting it and opening another window are the only
# two things a second click can sensibly mean, so if nothing said which one was
# wanted, ask. Either way confirm it is really dsh first: dsh answers 401 (and
# 403 on a rejected Host) without a browser cookie, and anything else on this
# port belongs to a different program.
$restarting = $false
$splashVisible = $false
$forceReload = $false
$openTarget = $Url

if ($running) {
    $action = Ask-Action $Port
    if ($action -eq 'cancel') { Write-Log 'ask: user chose to do nothing'; exit 0 }

    $probe = Probe-DshServer $Port
    Write-Log "probe: port $Port -> dsh=$($probe.IsDsh) ($($probe.Detail))"
    if (-not $probe.IsDsh) {
        Write-Log "reuse: port $Port is taken by $($probe.ProcessName) (PID $owner)"
        Show-Message "Port $Port is already used by another program (PID $owner), so DSH Web cannot start.`r`n`r`nClose that program, or start this launcher with another -Port." 'DSH Web' 16 45
        exit 1
    }
    # Prefer the token URL recorded by the last launch: it authenticates even a
    # browser that has no cookie for this server yet.
    if (Test-Path $UrlFile) {
        $stored = (Get-Content $UrlFile -Raw).Trim()
        if ($stored -match "^http://127\.0\.0\.1:$Port/\?token=\S+$") { $openTarget = $stored }
    }

    if ($action -eq 'restart') {
        Write-Log "restart: stopping the server on port $Port"
        # Every step is logged: this path used to stop silently right after the
        # card appeared, and without a trace there was nothing to go on.
        try {
            Initialize-Splash
            Write-Log 'restart: splash ready'
            $splashVisible = $true
            Set-Splash 'Restarting the server' ''
            $outcome = Stop-DshServer
            Write-Log "restart: stop outcome '$outcome'"
            if ($outcome -eq 'blocked') {
                Close-Splash
                Show-Message "Could not stop the dsh server on port $Port.`r`n`r`nEnd PID $owner in Task Manager and try again." 'DSH Web' 48 30
                exit 1
            }
        } catch {
            Write-Log "restart: FAILED after splash - $($_.Exception.Message)"
            Write-Log "restart: at $($_.InvocationInfo.PositionMessage)"
            Close-Splash
            Show-Message "Restarting dsh web failed:`r`n$($_.Exception.Message)" 'DSH Web' 16 45
            exit 1
        }
        $restarting = $true
        $forceReload = $true
        $running = $false
        $owner = 0
    } else {
        # Opening a window into a running server is quick, so the card appears
        # at once (no 2s delay) and disappears again right after.
        $splashVisible = $true
        Set-Splash 'Opening the interface' ''
    }
}

# --- start -------------------------------------------------------------------
if ($running) {
    Write-Log "reuse: port $Port already serving (PID $owner); opening $openTarget"
    if ($forceReload) { $openTarget += "&dsh_reload=$([int](Get-Date -UFormat %s))" }
    Set-Splash 'Opening the interface' ''
    Open-Gui $openTarget
    Wait-Pumping 900
    Close-Splash
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

# The process that just died still holds the previous stdout/stderr files for a
# moment, and creating a new process that redirects into them fails while it
# does. Retry instead of reporting a failure that clears up by itself.
$process = $null
Remove-Item $OutFile, $ErrFile -ErrorAction SilentlyContinue
for ($attempt = 1; $attempt -le 15 -and -not $process; $attempt++) {
    try {
        $process = Start-Process -FilePath $dsh.Node `
            -ArgumentList $startArgs `
            -WorkingDirectory $Workspace `
            -WindowStyle Hidden `
            -RedirectStandardOutput $OutFile `
            -RedirectStandardError $ErrFile `
            -PassThru
    } catch {
        Write-Log "start: attempt $attempt failed - $($_.Exception.Message)"
        Start-Sleep -Milliseconds 300
    }
}
if (-not $process) {
    Write-Log 'error: could not start dsh after 15 attempts'
    Close-Splash
    Show-Message "Starting dsh web failed: the previous server's log files stayed locked.`r`n`r`nTry again in a moment." 'DSH Web' 16 45
    exit 1
}
Write-Log "start: launched PID $($process.Id)"

# Watch for the port on another thread, so the loop below never blocks. See
# DshPortWatcher: the old inline probe cost ~520 ms per call and made the
# progress card stutter.
$readyFlag = Join-Path $env:TEMP "dsh-web-ready-$Port-$PID.flag"
Remove-Item $readyFlag -ErrorAction SilentlyContinue
$watcher = New-Object DshPortWatcher -ArgumentList $Port, $readyFlag
$watcher.Start()

$startedAt = Get-Date
$deadline = $startedAt.AddSeconds(45)
$lastSecond = -1
$portReady = $false
while ((Get-Date) -lt $deadline) {
    $waited = [int]((Get-Date) - $startedAt).TotalSeconds
    if (-not $script:Splash -and ($splashVisible -or $waited -ge $SplashDelaySeconds)) { Initialize-Splash }
    # Only touch the card when the text changes: it is animated by its own timer.
    if ($waited -ne $lastSecond -and (-not $restarting -or $waited -ge 1)) {
        $lastSecond = $waited
        Set-Splash 'Starting the server' "${waited}s"
    }
    if (Test-Path $readyFlag) { $portReady = $true; break }
    if ($process.HasExited) { break }
    Wait-Pumping 100
}
$watcher.Stop()
Remove-Item $readyFlag -ErrorAction SilentlyContinue

if ($portReady) {
    # Wait for the authenticated URL line, which dsh prints a moment after it
    # binds. Read only what is new since the last look instead of re-scanning the
    # whole file twice a second.
    $handoffUrl = ''
    $urlDeadline = (Get-Date).AddSeconds(25)
    $readFrom = 0L
    $lastSecond = -1
    while ((Get-Date) -lt $urlDeadline -and -not $handoffUrl) {
        $waited = [int]((Get-Date) - $startedAt).TotalSeconds
        if ($waited -ne $lastSecond) {
            $lastSecond = $waited
            Set-Splash 'Waiting for the interface' "${waited}s"
        }
        if (Test-Path $OutFile) {
            try {
                $stream = [System.IO.File]::Open($OutFile, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($stream.Length -gt $readFrom) {
                        [void]$stream.Seek($readFrom, 'Begin')
                        $buffer = New-Object byte[] ($stream.Length - $readFrom)
                        $read = $stream.Read($buffer, 0, $buffer.Length)
                        $readFrom += $read
                        $chunk = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                        $found = [regex]::Match($chunk, 'dsh web:\s+(\S+)')
                        if ($found.Success) { $handoffUrl = $found.Groups[1].Value }
                    }
                } finally { $stream.Close() }
            } catch { }
        }
        if (-not $handoffUrl) { Wait-Pumping 100 }
    }
    if ($handoffUrl) {
        try { Set-Content -Path $UrlFile -Value $handoffUrl -Encoding ASCII } catch { }
        Write-Log "start: ready on $handoffUrl (PID $($process.Id))"
    } else {
        Write-Log "start: ready on $Url (PID $($process.Id)); the authenticated URL line never appeared"
    }
    Set-Splash 'Opening the browser' ''
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
