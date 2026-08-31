[CmdletBinding()]
param (
    [string]$Mode = "screen", # screen | region | window
    [string]$SavePath = "",
    [switch]$CopyToClipboard,
    [int]$DelayMs = 250,
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

    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (IntPtr)(-4);
    public const int SRCCOPY = 0x00CC0020;
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

    public static Bitmap CaptureBounds(Rectangle bounds) {
        EnableDpiAwareness();
        IntPtr hdcScreen = GetDC(IntPtr.Zero);
        Bitmap bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr hdcBmp = g.GetHdc();
            BitBlt(hdcBmp, 0, 0, bounds.Width, bounds.Height, hdcScreen, bounds.X, bounds.Y, SRCCOPY);
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
    private Rectangle selectionRect;
    private bool isSelecting = false;
    public Bitmap CroppedResult { get; private set; }
    public bool IsCancelled { get; private set; }

    public RegionSelectionForm(Bitmap desktopImage) {
        NativeCapture.EnableDpiAwareness();
        this.fullScreenBmp = desktopImage;
        this.IsCancelled = true;
        Rectangle vBounds = SystemInformation.VirtualScreen;

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
        if (isSelecting) {
            int x = Math.Min(startPoint.X, e.X);
            int y = Math.Min(startPoint.Y, e.Y);
            int w = Math.Abs(startPoint.X - e.X);
            int h = Math.Abs(startPoint.Y - e.Y);
            selectionRect = new Rectangle(x, y, w, h);
            this.Invalidate();
        }
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
    }
}

public class WindowSelectionForm : Form {
    private Bitmap fullScreenBmp;
    private List<NativeCapture.WindowEntry> windowList;
    private int selectedIndex = -1;
    public Bitmap CroppedResult { get; private set; }
    public bool IsCancelled { get; private set; }

    public WindowSelectionForm(Bitmap desktopImage) {
        NativeCapture.EnableDpiAwareness();
        this.fullScreenBmp = desktopImage;
        this.IsCancelled = true;
        Rectangle vBounds = SystemInformation.VirtualScreen;

        this.windowList = NativeCapture.GetVisibleWindowsList();
        if (this.windowList.Count > 0) {
            this.selectedIndex = 0; // Pre-select foreground active window
        }

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

    private void OnKeyDown(object sender, KeyEventArgs e) {
        if (e.KeyCode == Keys.Escape) {
            IsCancelled = true;
            this.DialogResult = DialogResult.Cancel;
            this.Close();
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e) {
        Rectangle vBounds = SystemInformation.VirtualScreen;
        Point screenPt = new Point(vBounds.X + e.X, vBounds.Y + e.Y);

        int newIndex = -1;
        for (int i = 0; i < windowList.Count; i++) {
            if (windowList[i].Bounds.Contains(screenPt)) {
                newIndex = i;
                break;
            }
        }

        if (newIndex != selectedIndex) {
            selectedIndex = newIndex;
            this.Invalidate();
        }
    }

    private void OnMouseDown(object sender, MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) {
            Rectangle vBounds = SystemInformation.VirtualScreen;
            Rectangle cropRect = Rectangle.Empty;

            if (selectedIndex >= 0 && selectedIndex < windowList.Count) {
                Rectangle rawB = windowList[selectedIndex].Bounds;
                cropRect = new Rectangle(rawB.X - vBounds.X, rawB.Y - vBounds.Y, rawB.Width, rawB.Height);
            } else {
                cropRect = new Rectangle(0, 0, fullScreenBmp.Width, fullScreenBmp.Height);
            }

            cropRect = Rectangle.Intersect(new Rectangle(0, 0, fullScreenBmp.Width, fullScreenBmp.Height), cropRect);

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

    private void OnPaint(object sender, PaintEventArgs e) {
        e.Graphics.DrawImage(fullScreenBmp, 0, 0, this.Width, this.Height);
        Rectangle vBounds = SystemInformation.VirtualScreen;

        Rectangle localTargetRect = Rectangle.Empty;
        string titleText = "Click to capture window | ESC to cancel";

        if (selectedIndex >= 0 && selectedIndex < windowList.Count) {
            Rectangle rawB = windowList[selectedIndex].Bounds;
            localTargetRect = new Rectangle(rawB.X - vBounds.X, rawB.Y - vBounds.Y, rawB.Width, rawB.Height);
            titleText = string.Format("Window: {0} ({1} × {2} px)", windowList[selectedIndex].Title, rawB.Width, rawB.Height);
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
        $form = New-Object RegionSelectionForm($desktopBmp)
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
