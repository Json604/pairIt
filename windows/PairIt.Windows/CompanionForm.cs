using System.Diagnostics;
using PairIt.Core;
using PairIt.Windows.Audio;
using PairIt.Windows.Storage;
using QRCoder;

namespace PairIt.Windows;

internal sealed class CompanionForm : Form
{
    private readonly DesktopSessions sessions;
    private readonly LocalIdentity identity;
    private DesktopSettings preferences;
    private readonly ReleaseUpdates updates = new();
    private readonly Label status = TextLabel("No phones connected"), device = TextLabel(Environment.MachineName);
    private readonly Button phone = ActionButton("Phone"), computer = ActionButton("Computer");
    private readonly Button pair = ActionButton("Pair a phone"), disconnect = ActionButton("Disconnect");
    private readonly Panel outputs = new() { Dock = DockStyle.Top, Height = 65, BackColor = Color.Transparent };
    private readonly System.Windows.Forms.Timer updateTimer = new() { Interval = 900000, Enabled = true };
    private bool updating;
    private Form? pairingWindow;
    internal bool ExitRequested;

    public CompanionForm(DesktopSessions sessions, LocalIdentity identity)
    {
        this.sessions = sessions; this.identity = identity; preferences = SettingsStore.Load();
        Text = "PairIt - AudioRelay"; Font = new Font("Segoe UI", 9); BackColor = Color.FromArgb(250, 250, 250);
        ForeColor = Color.FromArgb(23, 23, 23); FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false; MaximizeBox = false; MinimizeBox = false; AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(300, 278); StartPosition = FormStartPosition.Manual;
        var content = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(14, 10, 14, 12), ColumnCount = 1, RowCount = 5, BackColor = BackColor };
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var height in new[] { 38, 30, 48, 65, 45 }) content.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, Margin = Padding.Empty };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 28)); header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 34));
        var logo = new PictureBox { Image = Icon.ExtractAssociatedIcon(Application.ExecutablePath)?.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Width = 22, Height = 22, Anchor = AnchorStyles.Left, AccessibleName = "PairIt logo" };
        var brand = TextLabel("PairIt"); brand.Font = new Font(Font.FontFamily, 12, FontStyle.Bold); brand.Anchor = AnchorStyles.Left; brand.Dock = DockStyle.Fill; brand.AutoEllipsis = true;
        var settings = ActionButton("⚙"); settings.AccessibleName = "Settings"; settings.Dock = DockStyle.Fill; settings.Click += (_, _) => { try { ShowSettings(); } catch { status.Text = "Audio settings unavailable."; } };
        header.Controls.Add(logo, 0, 0); header.Controls.Add(brand, 1, 0); header.Controls.Add(settings, 2, 0); content.Controls.Add(header, 0, 0);
        device.Font = new Font(Font.FontFamily, 11, FontStyle.Bold); device.Dock = DockStyle.Fill; device.AutoEllipsis = true; content.Controls.Add(device, 0, 1);
        status.Dock = DockStyle.Fill; status.ForeColor = Color.FromArgb(100, 100, 100); content.Controls.Add(status, 0, 2);
        var label = TextLabel("Audio output"); label.Dock = DockStyle.Top; label.Height = 20;
        var segment = new TableLayoutPanel { Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(3), BackColor = Color.FromArgb(238, 238, 238), ColumnCount = 2 };
        segment.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); segment.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        phone.Dock = computer.Dock = DockStyle.Fill; phone.Click += async (_, _) => await SetOutputAsync(false); computer.Click += async (_, _) => await SetOutputAsync(true);
        segment.Controls.Add(phone, 0, 0); segment.Controls.Add(computer, 1, 0); outputs.Controls.Add(segment); outputs.Controls.Add(label); content.Controls.Add(outputs, 0, 3);
        var actions = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(0, 8, 0, 0) };
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 55)); actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 45));
        pair.Dock = disconnect.Dock = DockStyle.Fill; pair.Click += async (_, _) => { try { await PairAsync(); } catch { status.Text = "Could not show pairing code."; } }; disconnect.Click += async (_, _) => await StopAllAsync();
        actions.Controls.Add(pair, 0, 0); actions.Controls.Add(disconnect, 1, 0); content.Controls.Add(actions, 0, 4); Controls.Add(content);
        updateTimer.Tick += async (_, _) => await updates.CheckAsync(); Activated += async (_, _) => await updates.CheckAsync();
        FormClosing += (_, e) => { if (!ExitRequested) { e.Cancel = true; Hide(); } };
        VisibleChanged += (_, _) => { if (!Visible) pairingWindow?.Close(); };
        Disposed += (_, _) => { updateTimer.Dispose(); updates.Dispose(); logo.Image?.Dispose(); pairingWindow?.Dispose(); };
        Render(sessions.Status);
    }
    private void Render(DesktopStatus value)
    {
        var ready = value.Receivers > 0;
        status.Text = value.Receivers > 0 ? $"Your phone{(value.Receivers > 1 ? " · +" + (value.Receivers - 1) : "")}\n{(value.ActiveReceivers > 0 && !value.ComputerOutput ? "Listening" : value.ComputerOutput ? "Computer output" : "Paused")}" : "No phones connected";
        outputs.Visible = ready; disconnect.Visible = ready || sessions.CurrentSettings.SharingEnabled;
        phone.Enabled = computer.Enabled = sessions.CurrentSettings.SharingEnabled && !updating;
        PairItAppearance.Select(phone, !value.ComputerOutput); PairItAppearance.Select(computer, value.ComputerOutput);
        PairItAppearance.Select(pair, !ready);
    }
    public void UpdateStatus(DesktopStatus value)
    {
        if (IsDisposed || Disposing || !IsHandleCreated) return;
        if (InvokeRequired) { try { BeginInvoke(() => UpdateStatus(value)); } catch (InvalidOperationException) { } return; }
        Render(value);
    }
    public void ShowPaired() { pairingWindow?.Close(); Render(sessions.Status); }
    public void Reveal()
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(Math.Max(area.Left, area.Right - Width - 12), Math.Max(area.Top, area.Bottom - Height - 12)); Show(); Activate();
    }
    public async Task StopAllAsync()
    {
        await ApplyAsync(preferences with { MicrophoneEnabled = false, SharingEnabled = false }); Render(sessions.Status);
    }
    private async Task ApplyAsync(DesktopSettings settings)
    {
        if (updating) return; updating = true; string? error = null;
        try { preferences = settings; if (!await SettingsApplication.ApplyAsync(sessions, settings, SettingsStore.Save)) error = "Settings could not be saved."; }
        catch { error = "Audio unavailable. Check Settings."; }
        finally { updating = false; Render(sessions.Status); if (error != null) status.Text = error; }
    }
    private async Task SetOutputAsync(bool useComputer)
    {
        if (updating) return; updating = true; Render(sessions.Status); string? error = null;
        try { await sessions.SetComputerOutputAsync(useComputer); }
        catch { error = "Could not switch output."; }
        finally { updating = false; Render(sessions.Status); if (error != null) status.Text = error; }
    }
    private async Task PairAsync()
    {
        if (!sessions.CurrentSettings.SharingEnabled)
        {
            var available = WindowsAudioEndpoints.List();
            var source = available.FirstOrDefault(x => x.Id == preferences.SourceEndpointId) ?? available.FirstOrDefault();
            if (source == null) { status.Text = "Choose an audio source in Settings."; return; }
            await ApplyAsync(preferences with { SourceEndpointId = source.Id, SharingEnabled = true });
            if (!sessions.CurrentSettings.SharingEnabled) return;
        }
        if (pairingWindow != null) { pairingWindow.Activate(); return; }
        var dialog = new Form { Text = "Pair a phone", ClientSize = new Size(300, 390), FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, BackColor = Color.White, Font = Font, StartPosition = FormStartPosition.CenterParent };
        pairingWindow = dialog;
        var addresses = new ComboBox { Dock = DockStyle.Top, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "Computer network address" };
        foreach (var address in NetworkAddresses.List()) addresses.Items.Add(address);
        var picture = new PictureBox { Width = 224, Height = 224, SizeMode = PictureBoxSizeMode.Zoom, AccessibleName = "Private pairing QR code" };
        var copy = ActionButton("Copy pairing code");
        addresses.SelectedIndexChanged += (_, _) => {
            if (addresses.SelectedItem is not LocalAddress address) return;
            using var data = QRCodeGenerator.GenerateQrCode(identity.PairingCode(address.Host), QRCodeGenerator.ECCLevel.M);
            using var renderer = new PngByteQRCode(data); using var stream = new MemoryStream(renderer.GetGraphic(6)); using var bitmap = Image.FromStream(stream);
            picture.Image?.Dispose(); picture.Image = new Bitmap(bitmap);
        };
        copy.Click += (_, _) => { try { if (addresses.SelectedItem is LocalAddress address) Clipboard.SetText(identity.PairingCode(address.Host)); } catch { copy.Text = "Clipboard unavailable"; } };
        var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(20, 14, 20, 14) };
        addresses.Width = 254; layout.Controls.Add(addresses); picture.Margin = new Padding(15, 6, 0, 6); layout.Controls.Add(picture); copy.Width = 254; layout.Controls.Add(copy); layout.Controls.Add(TextLabel("Keep this code private.")); layout.Controls.Add(PhoneDownloads()); dialog.Controls.Add(layout);
        dialog.FormClosed += (_, _) => { picture.Image?.Dispose(); pairingWindow = null; };
        if (addresses.Items.Count > 0) addresses.SelectedIndex = 0;
        dialog.Show(this);
    }
    private void ShowSettings()
    {
        using var dialog = new Form { Text = "Settings", ClientSize = new Size(300, 300), BackColor = Color.White, Font = Font, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterParent };
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(14) };
        panel.Controls.Add(TextLabel("Audio source"));
        var source = new ComboBox { Width = 266, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "Audio source" };
        foreach (var endpoint in WindowsAudioEndpoints.List()) source.Items.Add(endpoint);
        source.SelectedItem = source.Items.Cast<RenderEndpoint>().FirstOrDefault(x => x.Id == preferences.SourceEndpointId);
        if (source.SelectedIndex < 0 && source.Items.Count > 0) source.SelectedIndex = 0;
        panel.Controls.Add(source);
        var apply = ActionButton("Apply source"); apply.Click += async (_, _) => { if (source.SelectedItem is RenderEndpoint endpoint) await ApplyAsync(preferences with { SourceEndpointId = endpoint.Id }); }; panel.Controls.Add(apply);
        var explanation = TextLabel("Local speakers stay on. Use a virtual output to silence them."); explanation.Width = 266; explanation.Height = 45; panel.Controls.Add(explanation);
        var update = ActionButton(updates.Available == null ? "Check for updates" : "Get update"); update.Click += async (_, _) => { await updates.CheckAsync(); if (updates.Available != null) updates.Open(); else update.Text = "No update available"; }; panel.Controls.Add(update);
        var help = ActionButton("Help"); help.Click += (_, _) => { try { Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "README.md")) { UseShellExecute = true }); } catch { } }; panel.Controls.Add(help);
        panel.Controls.Add(PhoneDownloads());
        dialog.Controls.Add(panel); dialog.ShowDialog(this);
    }
    private static Control PhoneDownloads()
    {
        var row = new FlowLayoutPanel { Width = 266, Height = 40, WrapContents = false, Margin = Padding.Empty };
        foreach (var android in new[] { true, false }) {
            var button = ActionButton(android ? "Android ↗" : "iPhone ↗");
            var image = new Bitmap(18, 18);
            using (var g = Graphics.FromImage(image)) {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using var pen = new Pen(Color.FromArgb(30,30,30), 1.5f);
                if (android) {
                    g.DrawArc(pen, 3, 5, 12, 12, 180, 180); g.DrawLine(pen, 3, 11, 15, 11);
                    g.DrawLine(pen, 5, 6, 3, 3); g.DrawLine(pen, 13, 6, 15, 3);
                    g.FillEllipse(Brushes.Black, 6, 8, 1.5f, 1.5f); g.FillEllipse(Brushes.Black, 11, 8, 1.5f, 1.5f);
                } else { g.DrawRectangle(pen, 5, 2, 8, 14); g.DrawLine(pen, 8, 13, 10, 13); }
            }
            button.Image = image; button.TextImageRelation = TextImageRelation.ImageBeforeText;
            button.AccessibleName = android ? "Download PairIt for Android" : "PairIt for iPhone";
            var anchor = android ? "android" : "iphone";
            button.Click += (_, _) => { try { Process.Start(new ProcessStartInfo("https://pairit.kartikey.xyz/downloads.html#" + anchor) { UseShellExecute = true }); } catch { button.Text = "Open website"; } };
            button.Disposed += (_, _) => image.Dispose(); row.Controls.Add(button);
        }
        return row;
    }
    private static Label TextLabel(string text) => new() { Text = text, AutoSize = false, Height = 22, Width = 266, TextAlign = ContentAlignment.MiddleLeft, BackColor = Color.Transparent, Margin = Padding.Empty };
    private static Button ActionButton(string text) => new FrostButton { Text = text, AutoSize = false, Width = 130, Height = 34, Margin = new Padding(0, 2, 3, 2), Padding = Padding.Empty };
}
