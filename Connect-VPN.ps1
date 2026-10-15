<#
  One-click FortiClient SAML VPN login using screen clicks + typing.

  First time:   powershell -ExecutionPolicy Bypass -File Connect-VPN.ps1 -Setup
  Change only the username/password:  ... -SetCredentials
  Test without typing anything:       ... -DryRun
  Every day:    run Connect-VPN.vbs (or the desktop shortcut it creates)

  Credentials and click positions live in %LOCALAPPDATA%\VpnConnector.
  The password is encrypted with Windows DPAPI: only your Windows account on
  this PC can decrypt it.
#>
param([switch]$Setup, [switch]$SetCredentials, [switch]$DryRun)

$ErrorActionPreference = 'Stop'
$FortiExe = 'C:\Program Files\Fortinet\FortiClient\FortiClient.exe'
$DataDir  = Join-Path $env:LOCALAPPDATA 'VpnConnector'
$CfgPath  = Join-Path $DataDir 'config.json'
$PwPath   = Join-Path $DataDir 'password.dat'
$LogPath  = Join-Path $DataDir 'last-run.log'

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinInfo { public IntPtr Handle; public uint Pid; public string Title; public string Class; public int W; public int H; }

public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }

public static class Win {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    public static uint PidOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return pid; }

    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    public static void CloseWindow(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }  // WM_CLOSE
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    // Brings a window to the front without sending any key (a fake Alt press opens the window menu
    // and swallows the first typed character).
    public static void ForceForeground(IntPtr h) {
        uint pid;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out pid);
        uint cur = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != cur && AttachThreadInput(cur, fgThread, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (attached) AttachThreadInput(cur, fgThread, false);
    }
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

    public static List<WinInfo> VisibleWindows() {
        var list = new List<WinInfo>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            var cb2 = new StringBuilder(256);
            GetClassName(h, cb2, cb2.Capacity);
            RECT r; GetWindowRect(h, out r);
            uint pid; GetWindowThreadProcessId(h, out pid);
            list.Add(new WinInfo { Handle = h, Pid = pid, Title = sb.ToString(), Class = cb2.ToString(), W = r.Right - r.Left, H = r.Bottom - r.Top });
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
[void][Win]::SetProcessDPIAware()

# Input guard (tells you apart from the script), Unicode typer, and the cat banner.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// Tells real (physical) input from the script's own injected input, can swallow real input
// for a short, self-expiring period, and flags the Esc key as "cancel".
public static class InputGuard {
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct KBDLL { public uint vk, scan, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSLL { public int x, y; public uint data, flags, time; public IntPtr extra; }

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int c, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);

    static HookProc kbProc = KbCb, msProc = MsCb;
    static IntPtr kbHook, msHook;
    static long lastRealTicks;      // UTC ticks of the last real input; 0 = never
    static long blockUntil;         // while UtcNow < this, real input is swallowed
    static int expX = int.MinValue, expY = int.MinValue, prevX, prevY;
    static bool havePrev;
    public static volatile bool EscPressed;
    public static int RealCount;

    public static void Install() {
        IntPtr mod = GetModuleHandle(null);
        kbHook = SetWindowsHookEx(13, kbProc, mod, 0);
        msHook = SetWindowsHookEx(14, msProc, mod, 0);
    }
    public static void Uninstall() {
        if (kbHook != IntPtr.Zero) UnhookWindowsHookEx(kbHook);
        if (msHook != IntPtr.Zero) UnhookWindowsHookEx(msHook);
        kbHook = msHook = IntPtr.Zero;
    }
    public static bool Installed { get { return kbHook != IntPtr.Zero && msHook != IntPtr.Zero; } }
    public static void Lock(int ms) { blockUntil = DateTime.UtcNow.Ticks + ms * 10000L; }
    public static void Unlock() { blockUntil = 0; }
    static bool Blocking { get { return DateTime.UtcNow.Ticks < blockUntil; } }
    public static void ResetEsc() { EscPressed = false; }
    public static void ExpectCursor(int x, int y) { expX = x; expY = y; }
    public static long MsSinceRealInput() {
        long t = lastRealTicks;
        return t == 0 ? 1000000000L : (DateTime.UtcNow.Ticks - t) / 10000L;
    }
    public static bool ModifiersDown() {
        int[] keys = { 0x10, 0x11, 0x12, 0x5B, 0x5C, 0x01, 0x02 };
        foreach (int k in keys) if ((GetAsyncKeyState(k) & 0x8000) != 0) return true;
        return false;
    }

    static IntPtr KbCb(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            KBDLL k = (KBDLL)Marshal.PtrToStructure(l, typeof(KBDLL));
            if ((k.flags & 0x10) == 0) {                       // not injected = a human pressed it
                lastRealTicks = DateTime.UtcNow.Ticks; RealCount++;
                if (k.vk == 0x1B && (k.flags & 0x80) == 0) EscPressed = true;
                if (Blocking) return (IntPtr)1;
            }
        }
        return CallNextHookEx(kbHook, code, w, l);
    }

    static IntPtr MsCb(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            MSLL m = (MSLL)Marshal.PtrToStructure(l, typeof(MSLL));
            if ((m.flags & 3) == 0) {                          // not injected
                int msg = w.ToInt32();
                bool real = true;
                if (msg == 0x200) {                            // WM_MOUSEMOVE
                    bool own = (m.x == expX && m.y == expY);
                    int d = havePrev ? Math.Abs(m.x - prevX) + Math.Abs(m.y - prevY) : 0;
                    prevX = m.x; prevY = m.y; havePrev = true;
                    real = !own && d >= 2;
                }
                if (real) {
                    lastRealTicks = DateTime.UtcNow.Ticks; RealCount++;
                    if (Blocking) return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(msHook, code, w, l);
    }
}

// Types by Unicode character, so Caps Lock and the keyboard layout cannot change what is typed.
public static class Typer {
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);

    static void Send(ushort vk, ushort scan, uint flags) {
        INPUT[] a = new INPUT[1];
        a[0].type = 1;
        a[0].u.ki.wVk = vk; a[0].u.ki.wScan = scan; a[0].u.ki.dwFlags = flags;
        if (SendInput(1, a, Marshal.SizeOf(typeof(INPUT))) != 1) throw new InvalidOperationException("SendInput failed");
    }
    public static void TypeText(string s, int delayMs) {
        foreach (char c in s) { Send(0, c, 4); Send(0, c, 6); Thread.Sleep(delayMs); }   // 4=UNICODE, 2=KEYUP
    }
    public static void Enter() { Send(0x0D, 0, 0); Send(0x0D, 0, 2); }
}

class CatPanel : Panel {
    public string Face = "working";
    public CatPanel() { DoubleBuffered = true; }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.ScaleTransform(Width / 90f, Height / 90f);
        string st = Face;
        Color fur = st == "angry" ? Color.FromArgb(236, 104, 66) : Color.FromArgb(242, 174, 84);
        Color ink = Color.FromArgb(60, 36, 20);
        using (Brush b = new SolidBrush(fur))
        using (Pen outline = new Pen(ink, 2.5f))
        using (Pen thick = new Pen(ink, 3.5f))
        using (Brush white = new SolidBrush(Color.White))
        using (Brush black = new SolidBrush(Color.Black))
        using (Brush pink = new SolidBrush(Color.FromArgb(255, 150, 170))) {
            Point[] earL = { new Point(10, 36), new Point(14, 6), new Point(38, 22) };
            Point[] earR = { new Point(80, 36), new Point(76, 6), new Point(52, 22) };
            g.FillPolygon(b, earL); g.FillPolygon(b, earR);
            g.DrawPolygon(outline, earL); g.DrawPolygon(outline, earR);
            g.FillEllipse(b, 6, 18, 78, 66); g.DrawEllipse(outline, 6, 18, 78, 66);

            if (st == "happy") {
                g.DrawArc(thick, 22, 38, 18, 16, 200, 140);
                g.DrawArc(thick, 50, 38, 18, 16, 200, 140);
            } else if (st == "error") {
                g.FillEllipse(white, 22, 34, 20, 24); g.FillEllipse(white, 48, 34, 20, 24);
                g.DrawEllipse(outline, 22, 34, 20, 24); g.DrawEllipse(outline, 48, 34, 20, 24);
                g.FillEllipse(black, 29, 42, 6, 8); g.FillEllipse(black, 55, 42, 6, 8);
            } else if (st == "angry") {
                g.FillEllipse(white, 23, 41, 19, 15); g.FillEllipse(white, 48, 41, 19, 15);
                g.DrawEllipse(outline, 23, 41, 19, 15); g.DrawEllipse(outline, 48, 41, 19, 15);
                g.FillEllipse(black, 31, 44, 7, 9); g.FillEllipse(black, 52, 44, 7, 9);
                g.DrawLine(thick, 19, 33, 42, 43);      // angry brows
                g.DrawLine(thick, 71, 33, 48, 43);
            } else {
                g.FillEllipse(white, 23, 38, 19, 20); g.FillEllipse(white, 48, 38, 19, 20);
                g.DrawEllipse(outline, 23, 38, 19, 20); g.DrawEllipse(outline, 48, 38, 19, 20);
                g.FillEllipse(black, 29, 43, 8, 11); g.FillEllipse(black, 54, 43, 8, 11);
            }
            Point[] nose = { new Point(40, 61), new Point(50, 61), new Point(45, 67) };
            g.FillPolygon(pink, nose);
            if (st == "angry") {
                g.DrawArc(outline, 33, 69, 24, 14, 200, 140);          // frown
            } else if (st == "error") {
                g.FillEllipse(black, 39, 69, 12, 10);                  // open mouth
            } else {
                g.DrawArc(outline, 33, 62, 12, 11, 20, 140);           // smile
                g.DrawArc(outline, 45, 62, 12, 11, 20, 140);
            }
            g.DrawLine(outline, 8, 58, 28, 62); g.DrawLine(outline, 8, 68, 28, 66);
            g.DrawLine(outline, 82, 58, 62, 62); g.DrawLine(outline, 82, 68, 62, 66);
        }
    }
}

// Small always-on-top, click-through, never-focused banner in the top-left corner.
public class CatOverlay : Form {
    public static volatile string State = "working";
    public static volatile string Message = "";
    public static volatile bool CloseNow;
    public static string ImageDir = "";
    static Thread th;

    CatPanel cat; PictureBox pic; Label text; System.Windows.Forms.Timer timer; string shown = "";

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x80 | 0x20; return cp; }  // NOACTIVATE | TOOLWINDOW | TRANSPARENT
    }

    public CatOverlay() {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        Opacity = 0.97;
        Size = new Size(410, 118);
        cat = new CatPanel(); cat.Location = new Point(10, 14); cat.Size = new Size(90, 90);
        pic = new PictureBox(); pic.Location = cat.Location; pic.Size = cat.Size; pic.SizeMode = PictureBoxSizeMode.Zoom; pic.Visible = false;
        text = new Label(); text.Location = new Point(110, 10); text.Size = new Size(292, 98);
        text.Font = new Font("Segoe UI", 11f, FontStyle.Bold); text.ForeColor = Color.White; text.BackColor = Color.Transparent;
        Controls.Add(cat); Controls.Add(pic); Controls.Add(text);
        float sc;
        using (Graphics gg = CreateGraphics()) sc = gg.DpiX / 96f;
        if (sc > 1.01f) { Scale(new SizeF(sc, sc)); text.Font = new Font("Segoe UI", 11f * sc, FontStyle.Bold, GraphicsUnit.Pixel); }
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.Left + 14, wa.Top + 14);
        using (GraphicsPath p = new GraphicsPath()) {
            int r = 22;
            p.AddArc(0, 0, r, r, 180, 90); p.AddArc(Width - r, 0, r, r, 270, 90);
            p.AddArc(Width - r, Height - r, r, r, 0, 90); p.AddArc(0, Height - r, r, r, 90, 90);
            p.CloseFigure(); Region = new Region(p);
        }
        timer = new System.Windows.Forms.Timer(); timer.Interval = 120; timer.Tick += Tick; timer.Start();
    }

    void Tick(object s, EventArgs e) {
        if (CloseNow) { timer.Stop(); Close(); return; }
        string st = State;
        if (st == "working" && InputGuard.MsSinceRealInput() < 2000) st = "angry";
        string key = st + "|" + Message;
        if (key != shown) { shown = key; Apply(st); }
    }

    void Apply(string st) {
        string msg = Message;
        Color back = Color.FromArgb(30, 40, 66);
        string def = "Logging you in to VPN...\nHands off the mouse\nand keyboard please!\n(Esc = cancel)";
        if (st == "phone") { back = Color.FromArgb(24, 80, 70); def = "Approve the sign-in\non your phone now!"; }
        else if (st == "happy") { back = Color.FromArgb(24, 90, 50); def = "All done!"; }
        else if (st == "error") { back = Color.FromArgb(110, 30, 30); def = "Something went wrong."; }
        else if (st == "angry") { back = Color.FromArgb(125, 22, 22); msg = ""; def = "HEY! HANDS OFF!\nStop touching the mouse\nand keyboard!"; }
        BackColor = back;
        text.Text = msg.Length > 0 ? msg : def;
        cat.Face = st; cat.Invalidate();
        string file = Path.Combine(ImageDir, st + ".png");
        if (ImageDir.Length > 0 && File.Exists(file)) {
            try { pic.Image = Image.FromFile(file); pic.Visible = true; cat.Visible = false; return; } catch { }
        }
        pic.Visible = false; cat.Visible = true;
    }

    public static void Start(string imageDir) {
        ImageDir = imageDir ?? "";
        th = new Thread(delegate () {
            Application.EnableVisualStyles();
            InputGuard.Install();
            try { Application.Run(new CatOverlay()); } finally { InputGuard.Uninstall(); }
        });
        th.SetApartmentState(ApartmentState.STA);
        th.IsBackground = true;
        th.Start();
    }

    public static void Finish(string state, string msg, int lingerMs) {
        InputGuard.Unlock();
        Message = msg; State = state;
        if (lingerMs > 0 && th != null) { Thread.Sleep(lingerMs); CloseNow = true; th.Join(2000); }
    }
}
'@

function Log($msg) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $msg
    Write-Host $line
    try { Add-Content -Path $LogPath -Value $line } catch {}
}

function Get-FortiWindows {
    $pids = @(Get-Process FortiClient -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    [Win]::VisibleWindows() | Where-Object { $pids -contains $_.Pid -and $_.Title }
}

function Find-MainWindow {
    Get-FortiWindows | Where-Object { $_.Title -like 'FortiClient*' } | Select-Object -First 1
}

function Focus-Window($h) {
    if ([Win]::IsIconic($h)) { [void][Win]::ShowWindow($h, 9) }
    [Win]::ForceForeground($h)
    Start-Sleep -Milliseconds 300
}

# Programs whose window may receive the username/password. Anything else (a browser tab,
# Claude, Teams, a text editor...) is refused, so credentials can never be typed there.
$AllowedProcesses = @('FortiClient', 'FortiAuth', 'msedgewebview2')

function Get-ProcName([uint32]$procId) {
    try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { '' }
}

function Get-AllWindows { [Win]::VisibleWindows() }

function Get-SamlWindow {
    Get-AllWindows | Where-Object {
        $_.Title -like 'FortiClient SAML Authentication*' -and ($AllowedProcesses -contains (Get-ProcName $_.Pid))
    } | Select-Object -First 1
}

# Brings $h to the front and verifies it. Throws (so nothing is typed) if it can't be confirmed.
function Assert-Foreground($h, [string]$what) {
    for ($i = 0; $i -lt 6; $i++) {
        Focus-Window $h
        $fg = [Win]::GetForegroundWindow()
        if ($fg -eq $h) {
            $name = Get-ProcName ([Win]::PidOf($fg))
            if ($AllowedProcesses -contains $name) { return }
            throw "Refusing to type: front window belongs to '$name', not FortiClient. Nothing was typed."
        }
        Start-Sleep -Milliseconds 400
    }
    $fgName = Get-ProcName ([Win]::PidOf([Win]::GetForegroundWindow()))
    throw "Could not bring the sign-in window to the front for $what (front window is '$fgName'). Nothing was typed."
}

# Closes any leftover Microsoft sign-in window (after a dry run, a cancel or an error).
function Close-SamlWindows {
    foreach ($sw in @(Get-AllWindows | Where-Object { $_.Title -like 'FortiClient SAML Authentication*' })) {
        [Win]::CloseWindow($sw.Handle)
    }
}

function Click-At($x, $y) {
    [InputGuard]::ExpectCursor($x, $y)
    [void][Win]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    [Win]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero)
    [Win]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
}

# Typing is done by Unicode character (Caps Lock / keyboard layout cannot change it).
function Type-Text([string]$text) { [Typer]::TypeText($text, 12) }
function Press-Enter { [Typer]::Enter() }

function Check-Cancel {
    if ([InputGuard]::EscPressed) { throw 'Cancelled: you pressed Esc. Nothing more was typed.' }
}

# True when you have had your hands off the mouse and keyboard for $quietMs.
function Test-Quiet([int]$quietMs = 1200) {
    ([InputGuard]::MsSinceRealInput() -ge $quietMs) -and -not [InputGuard]::ModifiersDown()
}

# Waits until you stop touching things (the angry cat shows meanwhile); gives up after $maxSec.
function Wait-Quiet([int]$quietMs = 1200, [int]$maxSec = 40) {
    $deadline = (Get-Date).AddSeconds($maxSec)
    while ($true) {
        Check-Cancel
        if (Test-Quiet $quietMs) { return }
        if ((Get-Date) -gt $deadline) {
            throw 'You kept using the mouse/keyboard, so I stopped before typing anything. Run it again and keep your hands off.'
        }
        Start-Sleep -Milliseconds 150
    }
}

function Test-VpnConnected {
    $a = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
         Where-Object { $_.InterfaceDescription -like '*Fortinet SSL VPN*' }
    [bool]($a | Where-Object { $_.Status -eq 'Up' })
}

function Ensure-MainWindow($cfg) {
    $win = Find-MainWindow
    if (-not $win) {
        if (-not (Get-Process FortiClient -ErrorAction SilentlyContinue)) {
            Log 'Starting FortiClient'
            Start-Process $FortiExe -WorkingDirectory (Split-Path $FortiExe)
        } else {
            Log 'FortiClient is running but its window is hidden; asking it to show'
            Start-Process $FortiExe -WorkingDirectory (Split-Path $FortiExe)
        }
        $deadline = (Get-Date).AddSeconds(40)
        while (-not $win -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 700
            $win = Find-MainWindow
        }
    }
    if (-not $win) { throw 'FortiClient window did not appear within 40 s.' }
    if ($win.Title -eq 'Error') { throw 'FortiClient shows an error dialog; fix FortiClient first.' }
    $win
}

# ---------------------------------------------------------------- CHANGE CREDENTIALS
if ($SetCredentials) {
    if (-not (Test-Path $CfgPath)) { throw 'Run -Setup first.' }
    $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json
    Write-Host "Current username: $($cfg.Username)"
    $user = (Read-Host 'New username (press Enter to keep the current one)').Trim()
    if (-not $user) { $user = $cfg.Username }
    while ($true) {
        $p1 = Read-Host 'New password (typing is hidden)' -AsSecureString
        $p2 = Read-Host 'Type the password again' -AsSecureString
        $a = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
        try {
            $s1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($a)
            $s2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
            $same = ($s1 -ceq $s2) -and $s1.Length -gt 0
            $len = $s1.Length
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
            $s1 = $null; $s2 = $null
        }
        if ($same) { break }
        Write-Host 'The two passwords did not match (or were empty). Try again.' -ForegroundColor Yellow
    }
    $p1 | ConvertFrom-SecureString | Set-Content -Path $PwPath -Encoding ascii
    $cfg.Username = $user
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $CfgPath -Encoding utf8
    Write-Host "Saved. Username: $user   Password length: $len characters"
    return
}

# ---------------------------------------------------------------- SETUP
if ($Setup) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

    $user = Read-Host 'Username (e.g. you@company.com)'
    $sec  = Read-Host 'Password' -AsSecureString
    $sec | ConvertFrom-SecureString | Set-Content -Path $PwPath -Encoding ascii

    Write-Host "`nOpening FortiClient. Put its window where you want it, switch to the VPN"
    Write-Host 'page and make sure your VPN is selected. Put this console beside it so that'
    Write-Host 'the button you want to click stays visible.'
    $win = Ensure-MainWindow $null
    Read-Host 'Press Enter when FortiClient is ready'

    $win = Find-MainWindow
    $r = New-Object RECT
    [void][Win]::GetWindowRect($win.Handle, [ref]$r)
    $rect = @{ X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top }

    $clicks = @()
    $n = 1
    Write-Host "`nNow record the clicks, in order (e.g. the VPN dropdown, then your VPN name, then Connect)."
    Write-Host "If your VPN is already selected, a single click on 'Connect' is enough."
    while ($true) {
        $ans = Read-Host "Hover the mouse over click #$n, then press Enter here (type d + Enter when finished)"
        if ($ans -eq 'd') { break }
        $p = New-Object POINT
        [void][Win]::GetCursorPos([ref]$p)
        $clicks += @{ DX = $p.X - $rect.X; DY = $p.Y - $rect.Y; DelayAfterSec = 1 }
        Write-Host "  recorded offset ($($p.X - $rect.X), $($p.Y - $rect.Y))"
        $n++
    }
    if ($clicks.Count -eq 0) { throw 'No clicks recorded.' }

    $cfg = @{
        Username         = $user
        Window           = $rect
        Clicks           = $clicks
        LoginPageWaitSec = 2     # after the Microsoft page has loaded, before typing the username
        PasswordWaitSec  = 4     # after the username, before typing the password
        FirstEnterAfterSec = 8   # after the password, before the first 'stay signed in' Enter
        EnterEverySec    = 4     # repeat Enter until the tunnel is up
        TimeoutSec       = 150
    }
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $CfgPath -Encoding utf8

    # one-click launcher next to this script, plus a desktop shortcut
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ps1  = $MyInvocation.MyCommand.Path
    $vbs  = Join-Path $here 'Connect-VPN.vbs'
    @"
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$ps1""", 0, False
"@ | Set-Content -Path $vbs -Encoding ascii
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Connect VPN.lnk'
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sc.TargetPath = 'wscript.exe'
    $sc.Arguments = "`"$vbs`""
    $sc.IconLocation = "$FortiExe,0"
    $sc.Save()

    Write-Host "`nSetup done. Double-click 'Connect VPN' on your desktop (or pin it to the taskbar)."
    return
}

# ---------------------------------------------------------------- RUN
try {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Set-Content -Path $LogPath -Value ''
    if (-not (Test-Path $CfgPath) -or -not (Test-Path $PwPath)) { throw 'Not set up yet. Run with -Setup first.' }
    $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json

    if (Test-VpnConnected) { Log 'VPN is already connected.'; return }

    $sec  = Get-Content $PwPath | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    # The cat banner (top-left) shows that automation is running and scolds you if you touch anything.
    [InputGuard]::ResetEsc()
    [CatOverlay]::Start((Join-Path $DataDir 'cats'))
    Start-Sleep -Milliseconds 600

    $main = Ensure-MainWindow $cfg
    Start-Sleep -Seconds 2
    $w = $cfg.Window
    # 0x4 = SWP_NOZORDER, 0x10 = SWP_NOACTIVATE, 0x40 = SWP_SHOWWINDOW
    [void][Win]::ShowWindow($main.Handle, 9)
    [void][Win]::SetWindowPos($main.Handle, [IntPtr]::Zero, $w.X, $w.Y, $w.W, $w.H, 0x54)
    $before = @(Get-AllWindows | ForEach-Object { $_.Handle })

    foreach ($c in $cfg.Clicks) {
        # wait until you let go of the mouse/keyboard, then lock your input for a few seconds
        Wait-Quiet
        [InputGuard]::Lock(8000)
        try {
            Assert-Foreground $main.Handle 'the Connect click'
            Log "Click at ($($w.X + $c.DX), $($w.Y + $c.DY))"
            Click-At ($w.X + $c.DX) ($w.Y + $c.DY)
        } finally { [InputGuard]::Unlock() }
        Start-Sleep -Seconds $c.DelayAfterSec
    }

    # The Microsoft sign-in is either a new top-level window or embedded in the main one.
    # Log every new window so we can see exactly what it is.
    $saml = $null
    $seen = @{}
    $deadline = (Get-Date).AddSeconds(25)
    while (-not $saml -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        foreach ($nw in (Get-AllWindows | Where-Object { $before -notcontains $_.Handle })) {
            $pname = Get-ProcName $nw.Pid
            if (-not $seen.ContainsKey([string]$nw.Handle)) {
                $seen[[string]$nw.Handle] = 1
                Log "New window: process=$pname class=$($nw.Class) size=$($nw.W)x$($nw.H) title='$($nw.Title)'"
            }
            if (-not $saml -and $AllowedProcesses -contains $pname -and $nw.Title -like 'FortiClient SAML Authentication*') { $saml = $nw }
        }
    }
    $embedded = -not $saml
    Log ("Sign-in window: " + $(if ($saml) { "'$($saml.Title)' (new window)" } else { 'assumed embedded in main window' }))

    # The sign-in window is replaced while it loads, so always look it up by title, never by an old handle.
    function Get-Target {
        if ($embedded) { return $main.Handle }
        $deadline = (Get-Date).AddSeconds(10)
        do {
            $s = Get-SamlWindow
            if ($s) { return $s.Handle }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        throw 'The sign-in window is no longer open. Nothing was typed.'
    }

    # Wait for the Microsoft login page: the window title shows the page address once it has loaded.
    if (-not $embedded) {
        $lastTitle = ''
        $pageReady = $false
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $cur = Get-SamlWindow
            if ($cur) {
                $shown = $cur.Title -replace '\s*\(\d+ seconds\)', ''   # ignore the countdown
                if ($shown -ne $lastTitle) { $lastTitle = $shown; Log "Sign-in window title: $shown" }
                if ($shown -match '\[Sign in' -or ($shown -match '\[.+\]' -and $shown -notmatch '\[Loading\]|/remote/saml')) { $pageReady = $true; break }
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $pageReady) { Log 'Login page address not recognised; continuing after the fixed wait' }
    }
    # Get the FortiClient main window out of the way. It is only minimised: FortiClient must stay
    # running to receive the sign-in result, so closing it here would break the connection.
    if (-not $embedded -and ($null -eq $cfg.MinimizeFortiWindow -or $cfg.MinimizeFortiWindow)) {
        Log 'Minimising the FortiClient main window'
        [void][Win]::ShowWindow($main.Handle, 6)
        Start-Sleep -Seconds 1
        if (-not (Get-SamlWindow)) { throw 'The sign-in window disappeared after minimising FortiClient. Set "MinimizeFortiWindow": false in config.json.' }
    }
    Start-Sleep -Seconds $cfg.LoginPageWaitSec

    # SAFETY: type only after you have let go of the mouse/keyboard AND the sign-in window is
    # confirmed to be the front window. Your own input is swallowed while the script types, so a
    # stray key can never end up in the username/password box.
    Wait-Quiet
    [InputGuard]::Lock(20000)
    try {
        Assert-Foreground (Get-Target) 'the username'
        if ($DryRun) {
            Log 'DRY RUN: front window confirmed; would type username here. Stopping, nothing typed.'
            Close-SamlWindows
            [CatOverlay]::Finish('happy', 'Dry run OK - nothing was typed.', 2500)
            return
        }
        Log 'Typing username'
        Type-Text $cfg.Username
        Press-Enter
        Start-Sleep -Seconds $cfg.PasswordWaitSec

        Check-Cancel
        Assert-Foreground (Get-Target) 'the password'
        Log 'Typing password'
        Type-Text $password
        Press-Enter
    } finally {
        [InputGuard]::Unlock()
        $password = $null
    }

    Log 'Approve the sign-in on your phone...'
    [CatOverlay]::State = 'phone'
    Start-Sleep -Seconds $cfg.FirstEnterAfterSec
    $deadline = (Get-Date).AddSeconds($cfg.TimeoutSec)
    $goneSince = $null
    while (-not (Test-VpnConnected) -and (Get-Date) -lt $deadline) {
        Check-Cancel
        $t = if ($embedded) { $main } else { Get-SamlWindow }
        if ($t) {
            $goneSince = $null
            # press Enter only when you are not touching anything AND the sign-in window is confirmed in front
            if (Test-Quiet 800) {
                [InputGuard]::Lock(4000)
                try { Assert-Foreground $t.Handle 'Enter'; Press-Enter }
                catch { Log "Skipped Enter: $($_.Exception.Message)" }
                finally { [InputGuard]::Unlock() }
            } else { Log 'Skipped Enter: you are using the mouse/keyboard' }
        }
        elseif (-not $goneSince) { $goneSince = Get-Date }
        elseif (((Get-Date) - $goneSince).TotalSeconds -gt 3) { Log 'Sign-in window closed.'; break }
        Start-Sleep -Seconds $cfg.EnterEverySec
    }
    # The Microsoft window is gone: stop sending keys, give the tunnel a moment to come up, then finish.
    $end = (Get-Date).AddSeconds(30)
    while (-not (Test-VpnConnected) -and (Get-Date) -lt $end -and -not $embedded) { Start-Sleep -Seconds 1 }
    if (Test-VpnConnected) {
        Log 'VPN connected.'
        Close-SamlWindows
        if ($null -eq $cfg.CloseFortiWhenDone -or $cfg.CloseFortiWhenDone) {
            $fm = Find-MainWindow
            if ($fm) {
                Log 'Closing the FortiClient main window'
                [Win]::CloseWindow($fm.Handle)
                Start-Sleep -Seconds 5
                if (-not (Test-VpnConnected)) { throw 'Closing FortiClient dropped the VPN. Set "CloseFortiWhenDone": false in config.json.' }
            }
        }
        Log 'Done.'
        [CatOverlay]::Finish('happy', 'VPN connected!', 2500)
    } else { throw 'The sign-in finished or was closed, but the VPN did not connect.' }
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    [InputGuard]::Unlock()
    try { Close-SamlWindows } catch {}
    $short = $_.Exception.Message
    if ($short.Length -gt 105) { $short = $short.Substring(0, 102) + '...' }
    [CatOverlay]::Finish('error', $short, 8000)
    exit 1
}
