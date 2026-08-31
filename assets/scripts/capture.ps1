[CmdletBinding()]
param (
    [string]$Mode = "screen", # screen | region | window
    [string]$SavePath = "",
    [switch]$CopyToClipboard,
    [int]$DelayMs = 0,
    [string]$ShowMagnifier = "true"
)

Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class NativeCapture {
    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(IntPtr hdcDest, int nXDest, int nYDest, int nWidth, int nHeight, IntPtr hdcSrc, int nXSrc, int nYSrc, int dwRop);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (IntPtr)(-4);
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const int SRCCOPY = 0x00CC0020;
    public const int CAPTUREBLT = 0x40000000;
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    public const uint GW_HWNDNEXT = 2;

    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public class WindowEntry {
        public IntPtr Handle;
        public Rectangle Bounds;
        public string Title;
    }

    public static void EnableDpiAwareness() {
        try {
            SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        } catch {
            try { SetProcessDPIAware(); } catch {}
        }
    }

    public static void ForceForeground(IntPtr hWnd) {
        try {
            SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOMOVE | SWP_NOSIZE);
            SetForegroundWindow(hWnd);
            BringWindowToTop(hWnd);
        } catch {}
    }

    public static Bitmap CaptureBounds(Rectangle bounds) {
        EnableDpiAwareness();
        IntPtr hdcScreen = GetDC(IntPtr.Zero);
        Bitmap bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr hdcBmp = g.GetHdc();
            bool ok = BitBlt(hdcBmp, 0, 0, bounds.Width, bounds.Height, hdcScreen, bounds.X, bounds.Y, SRCCOPY | CAPTUREBLT);
            if (!ok) {
                BitBlt(hdcBmp, 0, 0, bounds.Width, bounds.Height, hdcScreen, bounds.X, bounds.Y, SRCCOPY);
            }
            g.ReleaseHdc(hdcBmp);
        }
        ReleaseDC(IntPtr.Zero, hdcScreen);
        return bmp;
    }

    public static Rectangle GetVirtualScreenBounds() {
        EnableDpiAwareness();
        return SystemInformation.VirtualScreen;
    }

    public static List<WindowEntry> GetVisibleWindowsList() {
        EnableDpiAwareness();
        List<WindowEntry> list = new List<WindowEntry>();
        IntPtr current = GetForegroundWindow();

        int safetyCount = 0;
        while (current != IntPtr.Zero && safetyCount < 100) {
            safetyCount++;
            if (IsWindowVisible(current) && !IsIconic(current)) {
                RECT rect;
                int res = DwmGetWindowAttribute(current, DWMWA_EXTENDED_FRAME_BOUNDS, out rect, Marshal.SizeOf(typeof(RECT)));
                if (res != 0) {
                    GetWindowRect(current, out rect);
                }

                int w = rect.Right - rect.Left;
                int h = rect.Bottom - rect.Top;

                if (w > 100 && h > 100) {
                    StringBuilder sb = new StringBuilder(256);
                    GetWindowText(current, sb, 256);
                    string title = sb.ToString();

                    if (title != "Program Manager" && title != "Desktop") {
                        list.Add(new WindowEntry {
                            Handle = current,
                            Bounds = new Rectangle(rect.Left, rect.Top, w, h),
                            Title = string.IsNullOrEmpty(title) ? "Application Window" : title
                        });
                    }
                }
            }
            current = GetWindow(current, GW_HWNDNEXT);
        }
        return list;
    }
}

public class RegionSelectionForm : Form {
    private Bitmap fullScreenBmp;
    private Point startPoint;
    private Point currentMousePoint = Point.Empty;
    private Rectangle selectionRect;
    private bool isSelecting = false;
    private bool showMagnifier = true;
    public Bitmap CroppedResult { get; private set; }
    public bool IsCancelled { get; private set; }

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
            return cp;
        }
    }

    public RegionSelectionForm(Bitmap desktopImage, bool showMagnifier = true) {
        NativeCapture.EnableDpiAwareness();
        this.fullScreenBmp = desktopImage;
        this.showMagnifier = showMagnifier;
        this.IsCancelled = true;
        Rectangle vBounds = SystemInformation.VirtualScreen;

        this.SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint |
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.Opaque,
            true
        );
        this.StartPosition = FormStartPosition.Manual;
        this.Location = vBounds.Location;
        this.Size = vBounds.Size;
        this.FormBorderStyle = FormBorderStyle.None;
        this.TopMost = true;
        this.ShowInTaskbar = false;
        this.DoubleBuffered = true;
        this.Cursor = Cursors.Cross;
        this.KeyPreview = true;

        this.MouseDown += OnMouseDown;
        this.MouseMove += OnMouseMove;
        this.MouseUp += OnMouseUp;
        this.KeyDown += OnKeyDown;
        this.Paint += OnPaint;
    }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        NativeCapture.ForceForeground(this.Handle);
    }

    private void OnKeyDown(object sender, KeyEventArgs e) {
        if (e.KeyCode == Keys.Escape) {
            IsCancelled = true;
            this.DialogResult = DialogResult.Cancel;
            this.Close();
        }
    }

    private void OnMouseDown(object sender, MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) {
            isSelecting = true;
            startPoint = e.Location;
            selectionRect = new Rectangle(e.X, e.Y, 0, 0);
            this.Invalidate();
        } else if (e.Button == MouseButtons.Right) {
            IsCancelled = true;
            this.DialogResult = DialogResult.Cancel;
            this.Close();
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e) {
        currentMousePoint = e.Location;
        if (isSelecting) {
            int x = Math.Min(startPoint.X, e.X);
            int y = Math.Min(startPoint.Y, e.Y);
            int w = Math.Abs(startPoint.X - e.X);
            int h = Math.Abs(startPoint.Y - e.Y);
            selectionRect = new Rectangle(x, y, w, h);
        }
        this.Invalidate();
    }

    private void OnMouseUp(object sender, MouseEventArgs e) {
        if (isSelecting && e.Button == MouseButtons.Left) {
            isSelecting = false;
            if (selectionRect.Width > 4 && selectionRect.Height > 4) {
                Rectangle cropRect = Rectangle.Intersect(
                    new Rectangle(0, 0, fullScreenBmp.Width, fullScreenBmp.Height),
                    selectionRect
                );

                if (cropRect.Width > 0 && cropRect.Height > 0) {
                    CroppedResult = fullScreenBmp.Clone(cropRect, fullScreenBmp.PixelFormat);
                    IsCancelled = false;
                    this.DialogResult = DialogResult.OK;
                } else {
                    IsCancelled = true;
                    this.DialogResult = DialogResult.Cancel;
                }
            } else {
                IsCancelled = true;
                this.DialogResult = DialogResult.Cancel;
            }
            this.Close();
        }
    }

    private void OnPaint(object sender, PaintEventArgs e) {
        e.Graphics.DrawImage(fullScreenBmp, 0, 0, this.Width, this.Height);

        using (GraphicsPath path = new GraphicsPath()) {
            path.AddRectangle(new Rectangle(0, 0, this.Width, this.Height));
            if (selectionRect.Width > 0 && selectionRect.Height > 0) {
                path.AddRectangle(selectionRect);
            }

            using (SolidBrush maskBrush = new SolidBrush(Color.FromArgb(120, 0, 0, 0))) {
                e.Graphics.FillPath(maskBrush, path);
            }
        }

        if (selectionRect.Width > 0 && selectionRect.Height > 0) {
            using (Pen borderPen = new Pen(Color.FromArgb(255, 0, 120, 215), 2)) {
                e.Graphics.DrawRectangle(borderPen, selectionRect);
            }
        }

        if (showMagnifier && !isSelecting) {
            DrawMagnifier(e.Graphics, currentMousePoint, this.Width, this.Height);
        }
    }

    private void DrawMagnifier(Graphics g, Point cursorPt, int formWidth, int formHeight) {
        if (fullScreenBmp == null || cursorPt.IsEmpty || cursorPt.X < 0 || cursorPt.Y < 0) return;

        int zoom = 4;
        int sampleSize = 25;
        int halfSample = sampleSize / 2;
        int magSize = sampleSize * zoom; // 100x100

        int magX = cursorPt.X + 22;
        int magY = cursorPt.Y + 22;

        if (magX + magSize + 10 > formWidth) magX = cursorPt.X - magSize - 22;
        if (magY + magSize + 10 > formHeight) magY = cursorPt.Y - magSize - 22;
        if (magX < 10) magX = 10;
        if (magY < 10) magY = 10;

        int srcX = cursorPt.X - halfSample;
        int srcY = cursorPt.Y - halfSample;

        Rectangle srcRect = new Rectangle(srcX, srcY, sampleSize, sampleSize);
        Rectangle destRect = new Rectangle(magX, magY, magSize, magSize);

        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.Half;

        using (GraphicsPath clipPath = new GraphicsPath()) {
            int radius = 8;
            clipPath.AddArc(magX, magY, radius * 2, radius * 2, 180, 90);
            clipPath.AddArc(magX + magSize - radius * 2, magY, radius * 2, radius * 2, 270, 90);
            clipPath.AddArc(magX + magSize - radius * 2, magY + magSize - radius * 2, radius * 2, radius * 2, 0, 90);
            clipPath.AddArc(magX, magY + magSize - radius * 2, radius * 2, radius * 2, 90, 90);
            clipPath.CloseFigure();

            GraphicsState state = g.Save();
            g.SetClip(clipPath);

            using (SolidBrush bg = new SolidBrush(Color.FromArgb(24, 24, 28))) {
                g.FillRectangle(bg, destRect);
            }

            Rectangle clampedSrc = Rectangle.Intersect(new Rectangle(0, 0, fullScreenBmp.Width, fullScreenBmp.Height), srcRect);
            if (clampedSrc.Width > 0 && clampedSrc.Height > 0) {
                int offX = clampedSrc.X - srcRect.X;
                int offY = clampedSrc.Y - srcRect.Y;
                Rectangle partialDest = new Rectangle(
                    magX + offX * zoom,
                    magY + offY * zoom,
                    clampedSrc.Width * zoom,
                    clampedSrc.Height * zoom
                );
                g.DrawImage(fullScreenBmp, partialDest, clampedSrc, GraphicsUnit.Pixel);
            }

            // Crosshairs
            int centerBoxX = magX + halfSample * zoom;
            int centerBoxY = magY + halfSample * zoom;

            using (Pen guidePen = new Pen(Color.FromArgb(200, 0, 150, 255), 1.5f)) {
                g.DrawLine(guidePen, magX + magSize / 2, magY, magX + magSize / 2, magY + magSize);
                g.DrawLine(guidePen, magX, magY + magSize / 2, magX + magSize, magY + magSize / 2);
            }

            using (Pen centerBoxPen = new Pen(Color.FromArgb(255, 255, 60, 60), 1.5f)) {
                g.DrawRectangle(centerBoxPen, centerBoxX, centerBoxY, zoom, zoom);
            }

            g.Restore(state);

            using (Pen border = new Pen(Color.FromArgb(255, 255, 255, 255), 1.5f)) {
                g.DrawPath(border, clipPath);
            }
        }
    }
}

public class WindowSelectionForm : Form {
    private Bitmap fullScreenBmp;
    private List<NativeCapture.WindowEntry> windowList;
    private NativeCapture.WindowEntry selectedWindow = null;
    public Bitmap CroppedResult { get; private set; }
    public bool IsCancelled { get; private set; }

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
            return cp;
        }
    }

    public WindowSelectionForm(Bitmap desktopImage) {
        NativeCapture.EnableDpiAwareness();
        this.fullScreenBmp = desktopImage;
        this.IsCancelled = true;
        this.windowList = NativeCapture.GetVisibleWindowsList();
        Rectangle vBounds = SystemInformation.VirtualScreen;

        this.SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint |
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.Opaque,
            true
        );
        this.StartPosition = FormStartPosition.Manual;
        this.Location = vBounds.Location;
        this.Size = vBounds.Size;
        this.FormBorderStyle = FormBorderStyle.None;
        this.TopMost = true;
        this.ShowInTaskbar = false;
        this.DoubleBuffered = true;
        this.Cursor = Cursors.Hand;
        this.KeyPreview = true;

        this.MouseDown += OnMouseDown;
        this.MouseMove += OnMouseMove;
        this.KeyDown += OnKeyDown;
        this.Paint += OnPaint;
    }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        NativeCapture.ForceForeground(this.Handle);
    }

    private void OnKeyDown(object sender, KeyEventArgs e) {
        if (e.KeyCode == Keys.Escape) {
            IsCancelled = true;
            this.DialogResult = DialogResult.Cancel;
            this.Close();
        }
    }

    private void OnMouseDown(object sender, MouseEventArgs e) {
        if (e.Button == MouseButtons.Left && selectedWindow != null) {
            Rectangle vBounds = SystemInformation.VirtualScreen;
            Rectangle rawB = selectedWindow.Bounds;
            Rectangle localTargetRect = new Rectangle(rawB.X - vBounds.X, rawB.Y - vBounds.Y, rawB.Width, rawB.Height);

            Rectangle cropRect = Rectangle.Intersect(
                new Rectangle(0, 0, fullScreenBmp.Width, fullScreenBmp.Height),
                localTargetRect
            );

            if (cropRect.Width > 0 && cropRect.Height > 0) {
                CroppedResult = fullScreenBmp.Clone(cropRect, fullScreenBmp.PixelFormat);
                IsCancelled = false;
                this.DialogResult = DialogResult.OK;
            } else {
                IsCancelled = true;
                this.DialogResult = DialogResult.Cancel;
            }
            this.Close();
        } else if (e.Button == MouseButtons.Right) {
            IsCancelled = true;
            this.DialogResult = DialogResult.Cancel;
            this.Close();
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e) {
        Point screenPt = Cursor.Position;
        NativeCapture.WindowEntry found = null;
        foreach (NativeCapture.WindowEntry w in windowList) {
            if (w.Bounds.Contains(screenPt)) {
                found = w;
                break;
            }
        }

        if (found != selectedWindow) {
            selectedWindow = found;
            this.Invalidate();
        }
    }

    private void OnPaint(object sender, PaintEventArgs e) {
        e.Graphics.DrawImage(fullScreenBmp, 0, 0, this.Width, this.Height);
        Rectangle vBounds = SystemInformation.VirtualScreen;
        Rectangle localTargetRect = Rectangle.Empty;

        if (selectedWindow != null) {
            Rectangle rawB = selectedWindow.Bounds;
            localTargetRect = new Rectangle(rawB.X - vBounds.X, rawB.Y - vBounds.Y, rawB.Width, rawB.Height);
        }

        using (GraphicsPath path = new GraphicsPath()) {
            path.AddRectangle(new Rectangle(0, 0, this.Width, this.Height));
            if (localTargetRect.Width > 0 && localTargetRect.Height > 0) {
                path.AddRectangle(localTargetRect);
            }

            using (SolidBrush maskBrush = new SolidBrush(Color.FromArgb(100, 0, 0, 0))) {
                e.Graphics.FillPath(maskBrush, path);
            }
        }

        if (localTargetRect.Width > 0 && localTargetRect.Height > 0) {
            using (Pen borderPen = new Pen(Color.FromArgb(255, 0, 120, 215), 3)) {
                e.Graphics.DrawRectangle(borderPen, localTargetRect);
            }
        }
    }
}
"@

try {
    if ($DelayMs -gt 0) {
        Start-Sleep -Milliseconds $DelayMs
    }

    $capturedBmp = $null

    if ($Mode -eq "region") {
        $desktopBmp = [NativeCapture]::CaptureBounds([NativeCapture]::GetVirtualScreenBounds())
        $magBool = ($ShowMagnifier -eq "true")
        $form = New-Object RegionSelectionForm($desktopBmp, $magBool)
        $res = $form.ShowDialog()

        if ($form.IsCancelled -or $form.CroppedResult -eq $null) {
            Write-Output "CANCELLED"
            $desktopBmp.Dispose()
            $form.Dispose()
            exit 0
        }

        $capturedBmp = $form.CroppedResult
        $desktopBmp.Dispose()
        $form.Dispose()
    }
    elseif ($Mode -eq "window") {
        $desktopBmp = [NativeCapture]::CaptureBounds([NativeCapture]::GetVirtualScreenBounds())
        $form = New-Object WindowSelectionForm($desktopBmp)
        $res = $form.ShowDialog()

        if ($form.IsCancelled -or $form.CroppedResult -eq $null) {
            Write-Output "CANCELLED"
            $desktopBmp.Dispose()
            $form.Dispose()
            exit 0
        }

        $capturedBmp = $form.CroppedResult
        $desktopBmp.Dispose()
        $form.Dispose()
    }
    else {
        # Entire Screen mode
        $bounds = [NativeCapture]::GetVirtualScreenBounds()
        $capturedBmp = [NativeCapture]::CaptureBounds($bounds)
    }

    if ($capturedBmp -eq $null) {
        Write-Output "ERROR|Failed to capture bitmap"
        exit 1
    }

    $saved = $false
    $copied = $false

    if ($SavePath -ne "") {
        $fullSavePath = [System.IO.Path]::GetFullPath($SavePath)
        $dir = [System.IO.Path]::GetDirectoryName($fullSavePath)
        if (-not [System.IO.Directory]::Exists($dir)) {
            [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        }

        $capturedBmp.Save($fullSavePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $SavePath = $fullSavePath
        $saved = $true
    }

    if ($CopyToClipboard) {
        [System.Windows.Forms.Clipboard]::SetImage($capturedBmp)
        $copied = $true
    }

    $w = $capturedBmp.Width
    $h = $capturedBmp.Height
    $capturedBmp.Dispose()

    if ($saved -and $copied) {
        Write-Output "SUCCESS|SAVED_AND_COPIED|$SavePath|$w|$h"
    } elseif ($saved) {
        Write-Output "SUCCESS|SAVED|$SavePath|$w|$h"
    } elseif ($copied) {
        Write-Output "SUCCESS|COPIED|$w|$h"
    } else {
        Write-Output "ERROR|No action performed"
    }
}
catch {
    Write-Output "ERROR|$($_.Exception.Message)"
    exit 1
}
