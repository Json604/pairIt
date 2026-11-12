using System.Diagnostics;
using PairIt.Core;
using PairIt.Windows.Audio;
using PairIt.Windows.Storage;

namespace PairIt.Windows;

internal sealed class CompanionForm : Form
{
    private readonly DesktopSessions sessions;
    private readonly LocalIdentity identity;
    private DesktopSettings preferences;
    private readonly ComboBox source = Choice(), addresses = Choice();
    private readonly Label status = TextLabel("Sharing stopped."), counts = TextLabel("0/4 connected");
    private readonly Button startSharing = ActionButton("Start sharing");
    private readonly TextBox pairing = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Height = 86, Dock = DockStyle.Top, Visible = false };
    private readonly ReleaseUpdates updates = new();
    private readonly Button updateButton = ActionButton("Get update");
    private bool updating;
    internal bool ExitRequested;

    public CompanionForm(DesktopSessions sessions, LocalIdentity identity)
    {
        this.sessions = sessions;
        this.identity = identity;
        preferences = SettingsStore.Load();
        Text = "PairIt";
        Font = new Font("Segoe UI", 10f);
        BackColor = PairItAppearance.Background;
        DoubleBuffered = true;
        ForeColor = PairItAppearance.Ink;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        MaximizeBox = false;
        MinimizeBox = false;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(432, 640);
        StartPosition = FormStartPosition.Manual;
        source.AccessibleName = "Computer audio output";
        addresses.AccessibleName = "Computer network address";
        pairing.AccessibleName = "Private pairing code";
        pairing.BackColor = PairItAppearance.Paper;
        pairing.ForeColor = PairItAppearance.Ink;

        var layout = new TableLayoutPanel { BackColor = Color.Transparent, Dock = DockStyle.Fill, Padding = new Padding(24, 18, 24, 16), ColumnCount = 1, RowCount = 7 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        var header = new TableLayoutPanel { BackColor = Color.Transparent, Dock = DockStyle.Fill, ColumnCount = 2 };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 50));
        header.Controls.Add(new Label { BackColor = Color.Transparent, Text = "PairIt ·", Font = PairItAppearance.Heading(24), AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
        
        updateButton.Dock = DockStyle.Fill;
        updateButton.AutoSize = true;
        updateButton.Click += (_, _) => { if (!updates.Open()) MessageBox.Show(this, "Couldn’t open the download. Try again.", "PairIt"); };
        void RenderUpdate() {
            if (IsDisposed || Disposing) return;
            updateButton.Visible = updates.Available != null;
            updateButton.Text = "Update available · " + updates.Available?.Version + " · Get update";
            updateButton.AccessibleDescription = "Download the new ZIP, then quit PairIt and extract the complete folder to update.";
        }
        updates.Changed += RenderUpdate;
        RenderUpdate();
        layout.Controls.Add(updateButton, 0, 0);
        layout.Controls.Add(header, 0, 1);
        layout.Controls.Add(TextLabel("WINDOWS  /  LOCAL AUDIO"), 0, 2);
        var navigation = new TableLayoutPanel { BackColor = Color.Transparent, Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0, 0, 0, 8) };
        var pages = new Panel { BackColor = Color.Transparent, Dock = DockStyle.Fill, Margin = new Padding(0, 14, 0, 8) };
        Control[] views = [BuildComputerTab(), BuildPairingTab()];
        string[] names = ["Audio relay", "Listen together"];
        var navigationButtons = new List<Button>();
        for (var index = 0; index < views.Length; index++)
        {
            var pageIndex = index;
            var page = views[index]; page.Dock = DockStyle.Fill; page.Visible = index == 0; pages.Controls.Add(page);
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / views.Length));
            var button = ActionButton(names[index]); button.Dock = DockStyle.Fill; button.Margin = new Padding(index == 0 ? 0 : 4, 0, 0, 0);
            button.AccessibleDescription = "Show " + names[index] + " controls";
            button.Click += (_, _) => {
                for (var i = 0; i < views.Length; i++) { views[i].Visible = i == pageIndex; PairItAppearance.Select(navigationButtons[i], i == pageIndex); }
            };
            navigationButtons.Add(button);PairItAppearance.Select(button, index == 0);navigation.Controls.Add(button, index, 0);
        }
        layout.Controls.Add(navigation, 0, 3);layout.Controls.Add(pages, 0, 4);
        status.Dock = DockStyle.Fill;status.MaximumSize = new Size(370, 0);status.AutoSize = true;status.Padding = new Padding(0, 10, 0, 10);
        layout.Controls.Add(status, 0, 5);
        var footer = new TableLayoutPanel { BackColor = Color.Transparent, Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        counts.Anchor = AnchorStyles.Left;counts.Margin = Padding.Empty;footer.Controls.Add(counts, 0, 0);
        var stop = ActionButton("Stop all");stop.Click += async (_, _) => await StopAllAsync();footer.Controls.Add(stop, 1, 0);
        layout.Controls.Add(footer, 0, 6);Controls.Add(layout);
        FormClosing += (_, args) => { if (!ExitRequested) { args.Cancel = true; Hide(); } };
        VisibleChanged += (_, _) => { if (!Visible) { pairing.Clear(); pairing.Visible = false; } };
        var updateTimer = new System.Windows.Forms.Timer { Interval = 900000, Enabled = true };
        updateTimer.Tick += async (_, _) => { if (Visible) await updates.CheckAsync(); };
        Disposed += (_, _) => updateTimer.Dispose();
        Activated += async (_, _) => await updates.CheckAsync();
        Disposed += (_, _) => updates.Dispose();
        RefreshChoices();
    }

    protected override void OnPaintBackground(PaintEventArgs e) => PairItAppearance.PaintBackdrop(e.Graphics, ClientSize);

    private Panel BuildComputerTab()
    {
        var (tab, panel) = Tab("Computer audio");
        Add(panel, Heading("Your sound.\nA little closer."));
        Add(panel, TextLabel("Send computer audio to your phone."));
        AddPhoneDownloads(panel);
        Add(panel, TextLabel("COMPUTER OUTPUT"));
        Add(panel, source);
        Add(panel, TextLabel("Choose the output your apps actually use. Local speakers keep playing; PairIt does not change or mute Windows outputs."));
        startSharing.Click += async (_, _) => await ConfigureAsync();
        PairItAppearance.Select(startSharing, true);
        Add(panel, startSharing);
        Add(panel, TextLabel("Up to four receivers share one source. Different headphones may have different audible delays."));
        Add(panel, TextLabel("Windows preview does not provide the Mac driver's video compensation. Protected media may be unavailable to loopback capture."));
        Add(panel, RefreshButton());
        return tab;
    }

    private Panel BuildPairingTab()
    {
        var (tab, panel) = Tab("Listen together");
        Add(panel, Heading("Same audio.\nMore company."));
        Add(panel, TextLabel("Up to four listeners. Connect each person’s headphones to their own phone, then pair every phone here and choose Computer."));
        Add(panel, TextLabel("Use the same Wi-Fi on all devices. Choose this computer’s reachable address."));
        AddPhoneDownloads(panel);
        Add(panel, addresses);
        addresses.SelectedIndexChanged += (_, _) => { pairing.Clear(); pairing.Visible = false; };
        var actions = new FlowLayoutPanel { BackColor = Color.Transparent, AutoSize = true, Dock = DockStyle.Top };
        var show = ActionButton("Show pairing code");
        var copy = ActionButton("Copy code");
        show.Click += (_, _) => ShowPairing(false);
        copy.Click += (_, _) => ShowPairing(true);
        actions.Controls.AddRange([show, copy]);
        Add(panel, actions);
        Add(panel, pairing);
        Add(panel, TextLabel("Keep the code private. Paste it into PairIt on your phone. Copying places pairing credentials on your clipboard."));
        Add(panel, TextLabel("Each listener controls their own volume and pause. Different headphones may have different delays."));
        Add(panel, RefreshButton());
        var help = new LinkLabel { BackColor = Color.Transparent, Text = "Connection help", AutoSize = true, LinkColor = PairItAppearance.Link };
        help.LinkClicked += (_, _) => OpenHelp();
        Add(panel, help);
        return tab;
    }

    private async Task ConfigureAsync()
    {
        if (updating) return;
        var selectedSource = source.SelectedItem as RenderEndpoint;
        var enabled = !sessions.CurrentSettings.SharingEnabled;
        if (enabled && selectedSource == null) { status.Text = "Select an available computer audio output first."; return; }
        preferences = new(selectedSource?.Id, null, false, false, enabled);
        await ApplyAsync(preferences);
    }

    private async Task ApplyAsync(DesktopSettings value)
    {
        updating = true;
        startSharing.Enabled = false;
        try
        {
            SettingsStore.Save(value);
            await sessions.ConfigureAsync(value);
            UpdateStatus(sessions.Status);
        }
        catch { status.Text = "Could not apply the setting. Check device availability and try again."; }
        finally { updating = false; startSharing.Enabled = true; }
    }

    public Task StopAllAsync() => ApplyAsync(preferences with { MicrophoneEnabled = false, SharingEnabled = false });

    public void UpdateStatus(DesktopStatus value)
    {
        if (IsDisposed || Disposing || !IsHandleCreated) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(() => UpdateStatus(value)); }
            catch (InvalidOperationException) { /* Window disposal raced the queued status. */ }
            return;
        }
        status.Text = value.Message;
        counts.Text = $"{value.Receivers}/4 connected · {value.ActiveReceivers} listening";
        var current = sessions.CurrentSettings;
        startSharing.Text = current.SharingEnabled ? "Stop sharing" : "Start sharing";
    }

    public void Reveal()
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(Math.Max(area.Left, area.Right - Width - 12), Math.Max(area.Top, area.Bottom - Height - 12));
        Show();
        Activate();
    }

    private void RefreshChoices()
    {
        try
        {
            var sourceId = (source.SelectedItem as RenderEndpoint)?.Id ?? preferences.SourceEndpointId;
            var endpoints = WindowsAudioEndpoints.List();
            source.Items.Clear();
            foreach (var endpoint in endpoints)
            {
                source.Items.Add(endpoint);
            }
            source.SelectedItem = endpoints.FirstOrDefault(endpoint => endpoint.Id == sourceId);
            var host = (addresses.SelectedItem as LocalAddress)?.Host;
            addresses.Items.Clear();
            foreach (var address in NetworkAddresses.List()) addresses.Items.Add(address);
            addresses.SelectedItem = addresses.Items.Cast<LocalAddress>().FirstOrDefault(address => address.Host == host);
            if (addresses.SelectedIndex < 0 && addresses.Items.Count > 0) addresses.SelectedIndex = 0;
        }
        catch { status.Text = "Could not list audio devices or network addresses. Refresh after reconnecting them."; }
    }

    private void ShowPairing(bool copy)
    {
        if (addresses.SelectedItem is not LocalAddress address) { status.Text = "Connect to a local network and refresh addresses first."; return; }
        var code = identity.PairingCode(address.Host);
        if (!copy) { pairing.Text = code; pairing.Visible = true; return; }
        try { Clipboard.SetText(code); status.Text = "Pairing code copied. Keep it private and clear your clipboard after pairing."; }
        catch { status.Text = "Clipboard is busy. Try again or use Show pairing code."; }
    }

    private void AddPhoneDownloads(TableLayoutPanel panel)
    {
        Add(panel, TextLabel("Install PairIt on your phone:"));
        foreach (var (title, platform) in new[] { ("Android downloads ↗", "android"), ("iPhone availability ↗", "iphone") })
        {
            var link = new LinkLabel { Text = title, AutoSize = true, BackColor = Color.Transparent, LinkColor = PairItAppearance.Link, MinimumSize = new Size(0, 28) };
            link.LinkClicked += (_, _) => {
                try { Process.Start(new ProcessStartInfo("https://pairit.kartikey.xyz/downloads.html#" + platform) { UseShellExecute = true }); }
                catch { MessageBox.Show(this, "Open pairit.kartikey.xyz/downloads.html on your phone.", "PairIt downloads"); }
            };
            Add(panel, link);
        }
    }

    private static void OpenHelp()
    {
        try { Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "README.md")) { UseShellExecute = true }); }
        catch { MessageBox.Show("Open README.md beside PairIt.exe for setup instructions.", "PairIt help"); }
    }

    private Button RefreshButton()
    {
        var button = ActionButton("Refresh devices & addresses");
        button.Click += (_, _) => RefreshChoices();
        return button;
    }

    private static ComboBox Choice() => new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Top, Width = 342, DropDownWidth = 530, BackColor = PairItAppearance.Paper, ForeColor = PairItAppearance.Ink, AccessibleName = "Choose endpoint or network address" };
    private static Button ActionButton(string text) => new FrostButton { Text = text, AutoSize = true, MinimumSize = new Size(0, 40), Padding = new Padding(12, 5, 12, 5) };
    private static Label TextLabel(string text) => new() { BackColor = Color.Transparent, Text = text, AutoSize = true, MaximumSize = new Size(338, 0), ForeColor = PairItAppearance.Secondary, Margin = new Padding(0, 0, 0, 12) };
    private static Label Heading(string text) => new() { BackColor = Color.Transparent, Text = text, Font = PairItAppearance.Heading(22), ForeColor = PairItAppearance.Ink, AutoSize = true, MaximumSize = new Size(338, 0), Margin = new Padding(0, 0, 0, 16) };
    private static (Panel Tab, TableLayoutPanel Panel) Tab(string name)
    {
        var tab = new FrostPanel { Padding = new Padding(16), AutoScroll = true, AccessibleName = name };
        var panel = new TableLayoutPanel { BackColor = Color.Transparent, Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, GrowStyle = TableLayoutPanelGrowStyle.AddRows };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));tab.Controls.Add(panel);return (tab, panel);
    }
    private static void Add(TableLayoutPanel panel, Control control)
    {
        control.Margin = new Padding(0, 0, 0, 14);
        panel.Controls.Add(control, 0, panel.RowCount++);
    }
}
