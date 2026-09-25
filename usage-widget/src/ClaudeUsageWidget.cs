using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

class UsageRow
{
    public int Used;
    public DateTime? Reset;
    public string ResetRaw;
}

class Widget : Form
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);

    const int CheckMinutes = 10;
    const int StaleMinutes = 25;

    static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    static readonly string Dir = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string OutFile = Path.Combine(Dir, "last-usage.txt");
    static readonly string TmpFile = Path.Combine(Dir, "last-usage.tmp");

    static readonly Color Bg = Color.FromArgb(30, 30, 30);
    static readonly Color Edge = Color.FromArgb(68, 68, 68);
    static readonly Color Track = Color.FromArgb(51, 51, 51);
    static readonly Color Muted = Color.FromArgb(153, 153, 153);
    static readonly Color Dim = Color.FromArgb(119, 119, 119);
    static readonly Color Hover = Color.FromArgb(70, 70, 70);

    UsageRow session, weekly;
    DateTime? updated;
    string problem;
    Process check;
    DateTime lastCheck = DateTime.MinValue;
    float s;
    Rectangle minRect, closeRect;
    int hover;
    Font fTitle, fMain, fSmall, fBtn;
    System.Windows.Forms.Timer timer;

    Widget()
    {
        Text = "Claude Usage";
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = true;
        StartPosition = FormStartPosition.Manual;
        DoubleBuffered = true;
        BackColor = Bg;

        using (Graphics g = CreateGraphics()) s = g.DpiX / 96f;
        fTitle = new Font("Segoe UI", 8f);
        fMain = new Font("Segoe UI", 9f);
        fSmall = new Font("Segoe UI", 8f);
        fBtn = new Font("Segoe UI", 9f);

        Size = new Size(P(230), P(116));
        Rectangle area = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(area.Right - Width - P(20), area.Bottom - Height - P(20));
        closeRect = new Rectangle(Width - P(26), P(6), P(20), P(18));
        minRect = new Rectangle(closeRect.X - P(22), P(6), P(20), P(18));

        using (GraphicsPath path = RoundRect(new Rectangle(0, 0, Width, Height), P(8)))
            Region = new Region(path);

        ContextMenu = new ContextMenu(new[] { new MenuItem("Close", delegate { Close(); }) });

        LoadResult(OutFile, true);

        timer = new System.Windows.Forms.Timer();
        timer.Interval = 15000;
        timer.Tick += delegate { Tick(); };
        timer.Start();
        Tick();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.Style |= 0x20000;
            return cp;
        }
    }

    int P(float v) { return (int)Math.Round(v * s); }

    static bool ClaudeRunning()
    {
        Process[] procs = Process.GetProcessesByName("claude");
        bool any = procs.Length > 0;
        foreach (Process p in procs) p.Dispose();
        return any;
    }

    static string FindClaude()
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in path.Split(';'))
        {
            if (dir.Trim().Length == 0) continue;
            foreach (string name in new[] { "claude.exe", "claude.cmd" })
            {
                try
                {
                    string candidate = Path.Combine(dir.Trim(), name);
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
        }

        string newest = null;
        DateTime newestTime = DateTime.MinValue;
        foreach (string editor in new[] { ".vscode", ".vscode-insiders", ".cursor", ".windsurf" })
        {
            string root = Path.Combine(Home, editor, "extensions");
            if (!Directory.Exists(root)) continue;
            foreach (string ext in Directory.GetDirectories(root, "anthropic.claude-code-*"))
            {
                string candidate = Path.Combine(ext, @"resources\native-binary\claude.exe");
                if (!File.Exists(candidate)) continue;
                DateTime t = File.GetLastWriteTime(candidate);
                if (t > newestTime) { newest = candidate; newestTime = t; }
            }
        }
        return newest;
    }

    void Tick()
    {
        if (check != null)
        {
            if (!check.HasExited) { Invalidate(); return; }
            check.Dispose();
            check = null;
            if (LoadResult(TmpFile, false))
            {
                File.Copy(TmpFile, OutFile, true);
                problem = null;
            }
            else if (!updated.HasValue) problem = "usage not available for this login";
        }
        if ((DateTime.Now - lastCheck).TotalMinutes >= CheckMinutes && ClaudeRunning()) StartCheck();
        Invalidate();
    }

    void StartCheck()
    {
        lastCheck = DateTime.Now;
        string claude = FindClaude();
        if (claude == null) { problem = "Claude CLI not found"; return; }
        try
        {
            string cmd = "/s /c \"\"" + claude + "\" -p /usage --no-session-persistence > \"" + TmpFile + "\" 2>&1\"";
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", cmd);
            psi.WorkingDirectory = Home;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.EnvironmentVariables["USAGE_WIDGET_POLL"] = "1";
            check = Process.Start(psi);
        }
        catch { check = null; }
    }

    bool LoadResult(string file, bool fromCache)
    {
        if (!File.Exists(file)) return false;
        string text;
        try { text = File.ReadAllText(file, Encoding.UTF8); } catch { return false; }
        UsageRow a = ParseRow(text, @"Current session:");
        UsageRow b = ParseRow(text, @"Current week \(all models\):") ?? ParseRow(text, @"Current week[^:\n]*:");
        if (a == null && b == null) return false;
        session = a;
        weekly = b;
        updated = fromCache ? File.GetLastWriteTime(file) : DateTime.Now;
        return true;
    }

    static readonly string[] ResetFormats =
    {
        "MMM d, h:mmtt", "MMM d, htt", "MMM d, H:mm",
        "d MMM, h:mmtt", "d MMM, htt", "d MMM, H:mm",
        "h:mmtt", "htt", "H:mm"
    };

    static UsageRow ParseRow(string text, string label)
    {
        Match m = Regex.Match(text, label + @"[^\n]*?(\d+)% used[^\n]*?resets ([^\n(]+)");
        if (!m.Success) return null;
        UsageRow r = new UsageRow();
        r.Used = Math.Min(100, int.Parse(m.Groups[1].Value));
        r.ResetRaw = Regex.Replace(m.Groups[2].Value, @"\s+", " ").Trim();
        DateTime dt;
        if (DateTime.TryParseExact(r.ResetRaw.ToUpperInvariant(), ResetFormats, CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces, out dt))
        {
            if (dt < DateTime.Now.AddDays(-1)) dt = dt.AddYears(1);
            r.Reset = dt;
        }
        return r;
    }

    static Color Stage(int used)
    {
        if (used >= 90) return Color.FromArgb(229, 72, 77);
        if (used >= 75) return Color.FromArgb(247, 107, 21);
        if (used >= 50) return Color.FromArgb(245, 217, 10);
        return Color.FromArgb(70, 167, 88);
    }

    static string ResetText(UsageRow row)
    {
        if (!row.Reset.HasValue) return string.IsNullOrEmpty(row.ResetRaw) ? "" : "resets " + row.ResetRaw;
        CultureInfo c = CultureInfo.InvariantCulture;
        DateTime dt = row.Reset.Value;
        if (dt.Date == DateTime.Today) return "resets " + dt.ToString("h:mm tt", c);
        return "resets " + dt.ToString("ddd h:mm tt", c);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

        using (GraphicsPath path = RoundRect(new Rectangle(0, 0, Width - 1, Height - 1), P(8)))
        using (Pen pen = new Pen(Edge))
            g.DrawPath(pen, path);

        int pad = P(10);
        int w = Width - pad * 2;
        TextRenderer.DrawText(g, "Claude usage", fTitle, new Point(pad, P(8)), Muted);

        DrawButton(g, minRect, "−", hover == 1);
        DrawButton(g, closeRect, "✕", hover == 2);

        DrawRow(g, P(32), session, "Session", pad, w);
        DrawRow(g, P(64), weekly, "Weekly", pad, w);

        string status;
        Color statusColor = Dim;
        if (updated.HasValue)
        {
            TimeSpan age = DateTime.Now - updated.Value;
            if (age.TotalMinutes < 1) status = "updated just now";
            else if (age.TotalHours < 1) status = "updated " + (int)age.TotalMinutes + "m ago";
            else status = "updated " + (int)age.TotalHours + "h ago";
            if (age.TotalMinutes > StaleMinutes) statusColor = Stage(80);
        }
        else if (problem != null) { status = problem; statusColor = Stage(80); }
        else status = check != null ? "fetching usage..." : "waiting for Claude";
        TextRenderer.DrawText(g, status, fSmall, new Point(pad, P(96)), statusColor);
    }

    void DrawRow(Graphics g, int y, UsageRow row, string name, int pad, int w)
    {
        string label = row == null ? name + "  --" : name + "  " + row.Used + "%";
        TextRenderer.DrawText(g, label, fMain, new Point(pad, y), Color.White);
        if (row != null)
        {
            string reset = ResetText(row);
            Size sz = TextRenderer.MeasureText(g, reset, fSmall);
            TextRenderer.DrawText(g, reset, fSmall, new Point(pad + w - sz.Width, y + P(2)), Muted);
        }
        int barY = y + P(19);
        using (SolidBrush b = new SolidBrush(Track)) g.FillRectangle(b, pad, barY, w, P(5));
        if (row != null && row.Used > 0)
            using (SolidBrush b = new SolidBrush(Stage(row.Used)))
                g.FillRectangle(b, pad, barY, (int)(w * row.Used / 100f), P(5));
    }

    void DrawButton(Graphics g, Rectangle r, string glyph, bool hot)
    {
        if (hot)
            using (GraphicsPath p = RoundRect(r, P(3)))
            using (SolidBrush b = new SolidBrush(Hover))
                g.FillPath(b, p);
        TextRenderer.DrawText(g, glyph, fBtn, r, Muted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }

    static GraphicsPath RoundRect(Rectangle r, int radius)
    {
        int d = radius * 2;
        GraphicsPath p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        int h = minRect.Contains(e.Location) ? 1 : closeRect.Contains(e.Location) ? 2 : 0;
        if (h != hover) { hover = h; Invalidate(); }
        Cursor = h != 0 ? Cursors.Hand : Cursors.Default;
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        if (hover != 0) { hover = 0; Invalidate(); }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        if (minRect.Contains(e.Location)) { WindowState = FormWindowState.Minimized; return; }
        if (closeRect.Contains(e.Location)) { Close(); return; }
        ReleaseCapture();
        SendMessage(Handle, 0xA1, 2, 0);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        timer.Stop();
        if (check != null && !check.HasExited)
        {
            try { check.Kill(); } catch { }
        }
        base.OnFormClosed(e);
    }

    [STAThread]
    static void Main()
    {
        bool created;
        using (Mutex mutex = new Mutex(true, @"Local\ClaudeCodeWindowsKit.UsageWidget", out created))
        {
            if (!created) return;
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new Widget());
        }
    }
}
