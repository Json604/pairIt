using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PairIt.Windows;

internal static class PairItAppearance
{
    private static readonly PrivateFontCollection Fonts = LoadFonts();
    public static Color Background => SystemInformation.HighContrast ? SystemColors.Control : Color.FromArgb(246, 246, 248);
    public static Color Paper => SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(250, 250, 250);
    public static Color Ink => SystemInformation.HighContrast ? SystemColors.ControlText : Color.FromArgb(25, 25, 25);
    public static Color Secondary => SystemInformation.HighContrast ? SystemColors.ControlText : Color.FromArgb(97, 97, 97);
    public static Color Accent => SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(30, 110, 240);
    public static Color Link => SystemInformation.HighContrast ? SystemColors.HotTrack : Color.FromArgb(35, 35, 35);
    public static Font Heading(float size) => new(Fonts.Families.FirstOrDefault() ?? FontFamily.GenericSansSerif, size);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, [MarshalAs(UnmanagedType.Bool)] out bool enabled, uint flags);
    public static bool AllowsMotion => !SystemInformation.HighContrast
        && SystemParametersInfo(0x1042 /* SPI_GETCLIENTAREAANIMATION */, 0, out bool enabled, 0) && enabled;
    public static void Select(Button button, bool selected)
    {
        if (button is FrostButton frost) frost.Primary = selected;
        button.ForeColor = selected ? (SystemInformation.HighContrast ? SystemColors.HighlightText : Color.White) : Ink;
        button.Invalidate();
    }
    public static GraphicsPath Rounded(RectangleF bounds, float diameter)
    {
        var shape = new GraphicsPath();
        diameter = Math.Min(diameter, Math.Min(bounds.Width, bounds.Height));
        shape.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        shape.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        shape.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        shape.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        shape.CloseFigure(); return shape;
    }
    public static void PaintBackdrop(Graphics graphics, Size size)
    {
        if (size.Width < 1 || size.Height < 1) return;
        graphics.Clear(Background);
        if (SystemInformation.HighContrast) return;
        // Neutral cards and controls; the blue accent stays in the background.
        using var baseFill = new LinearGradientBrush(new Rectangle(Point.Empty, size), Color.White, Color.FromArgb(226, 234, 247), 90);
        graphics.FillRectangle(baseFill, new Rectangle(Point.Empty, size));
    }
    private static PrivateFontCollection LoadFonts()
    {
        var result = new PrivateFontCollection();
        try { result.AddFontFile(Path.Combine(AppContext.BaseDirectory, "Fonts", "ChakraPetch-Regular.ttf")); }
        catch (Exception error) when (error is IOException or ArgumentException or System.Runtime.InteropServices.ExternalException) { }
        return result;
    }
}

/// Solid neutral cards over the static backdrop.
internal sealed class FrostPanel : Panel
{
    public FrostPanel()
    {
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        base.OnPaintBackground(e);
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = PairItAppearance.Rounded(new RectangleF(0, 0, Width - 1, Height - 1), 36 * DeviceDpi / 96f);
        using var fill = new SolidBrush(SystemInformation.HighContrast ? PairItAppearance.Paper : Color.White);
        using var edge = new Pen(SystemInformation.HighContrast ? SystemColors.ControlText : Color.FromArgb(220, Color.White));
        e.Graphics.FillPath(fill, shape);e.Graphics.DrawPath(edge, shape);
    }
}

internal sealed class FrostButton : Button
{
    internal bool Primary;
    private bool pressed, hovered;
    private float pressAmount;
    public FrostButton()
    {
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;FlatAppearance.BorderSize = 0;
        BackColor = Color.Transparent;ForeColor = PairItAppearance.Ink;
        UseVisualStyleBackColor = false;
    }
    protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate();base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovered = false; SetPressed(false); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if(e.Button == MouseButtons.Left) SetPressed(true); base.OnMouseDown(e); }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (Capture && e.Button == MouseButtons.Left) SetPressed(ClientRectangle.Contains(e.Location));
        base.OnMouseMove(e);
    }
    protected override void OnMouseUp(MouseEventArgs e) { SetPressed(false); base.OnMouseUp(e); }
    protected override void OnMouseCaptureChanged(EventArgs e) { if (!Capture) SetPressed(false); base.OnMouseCaptureChanged(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if(e.KeyCode == Keys.Space) SetPressed(true, false); base.OnKeyDown(e); }
    protected override void OnKeyUp(KeyEventArgs e) { SetPressed(false, false); base.OnKeyUp(e); }
    protected override void OnLostFocus(EventArgs e) { SetPressed(false, false); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { if(!Enabled) SetPressed(false, false); base.OnEnabledChanged(e); }
    protected override void OnVisibleChanged(EventArgs e) { if(!Visible) SetPressed(false, false); base.OnVisibleChanged(e); }
    private void SetPressed(bool value, bool animate = true)
    {
        pressed = value && Enabled;
        pressAmount = pressed && animate && PairItAppearance.AllowsMotion ? 1 : 0;
        Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float insetX = Width * .015f * pressAmount, insetY = Height * .015f * pressAmount;
        using var shape = PairItAppearance.Rounded(new RectangleF(insetX, insetY, Width - 1 - insetX * 2, Height - 1 - insetY * 2), 24 * DeviceDpi / 96f);
        var color = SystemInformation.HighContrast ? (Primary ? SystemColors.Highlight : SystemColors.Control)
            : Primary ? Color.FromArgb(pressed ? 70 : hovered ? 40 : 25, pressed ? 70 : hovered ? 40 : 25, pressed ? 70 : hovered ? 40 : 25)
            : Color.FromArgb(pressed ? 215 : hovered ? 230 : 240, pressed ? 215 : hovered ? 230 : 240, pressed ? 215 : hovered ? 230 : 240);
        using var fill = new SolidBrush(Enabled ? color : PairItAppearance.Background);
        using var edge = new Pen(SystemInformation.HighContrast ? SystemColors.ControlText : Color.FromArgb(210, Color.White));
        e.Graphics.FillPath(fill, shape);e.Graphics.DrawPath(edge, shape);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Enabled ? ForeColor : SystemColors.GrayText,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -5, -5), ForeColor, color);
    }
}
