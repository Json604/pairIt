using System.Net.NetworkInformation;
using System.Net.Sockets;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Styling;
using Avalonia.Layout;
using Avalonia.Input.Platform;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using PairIt.Core;
using QRCoder;

namespace PairIt.Linux;

internal sealed class CompanionWindow : Window
{
    private readonly ComboBox outputs = new() { Foreground = Brush.Parse("#171717"), Background = Brush.Parse("#EEEEEE"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox addresses = new() { Foreground = Brush.Parse("#171717"), Background = Brush.Parse("#EEEEEE"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock status = Label("Getting ready…");
    private readonly Button phone = new() { Content = "Phone headphones" }, computer = new() { Content = "Computer speakers" };
    private readonly Button playback=new(){Content="Resume audio",Height=40};
    private bool playbackBusy;
    private readonly Button show = new() { Content = "Pair a phone" };
    private LocalIdentity? identity;
    private DesktopSessions? sessions;
    private RelayServer? server;
    private ComputerDiscovery? discovery;
    private FileStream? instance;
    private bool busy, closing, closed;
    private Window? pairingWindow, settingsWindow;
    private DesktopTray? tray;
    private bool expandedForPlayback;
    private readonly StackPanel outputArea = new() { Spacing = 7 };
    private readonly Button disconnect = new() { Content = "Disconnect" };
    private readonly Button updateNotice = new() { IsVisible = false, HorizontalAlignment = HorizontalAlignment.Stretch,
        Background = Brush.Parse("#E8F0FA"), Foreground = Brush.Parse("#173C68"), CornerRadius = new CornerRadius(9), MinHeight = 36 };
    private readonly ReleaseUpdates? releaseUpdates;
    private readonly DispatcherTimer? updateTimer;

    public CompanionWindow(bool startServices = true)
    {
        Title = "PairIt - AudioRelay"; Width = 340; Height = 230; MinWidth = 300; MinHeight = 220;
        CanResize = true; WindowStartupLocation = WindowStartupLocation.CenterScreen; RequestedThemeVariant = ThemeVariant.Light;
        Background = Brush.Parse("#FAFAFA"); Foreground = Brush.Parse("#171717");
        var panel = new StackPanel { Margin = new Thickness(14, 10, 14, 12), Spacing = 10 };
        var header = new DockPanel { Height = 28, LastChildFill = false };
        var settings = new Button { Content = "⚙", Width = 32, Height = 28, Padding = new Thickness(0) };
        settings.Click += (_, _) => ShowSettings(); DockPanel.SetDock(settings, Dock.Right); header.Children.Add(settings);
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7, VerticalAlignment = VerticalAlignment.Center };
        try { using var stream = Avalonia.Platform.AssetLoader.Open(new Uri("avares://PairIt/PairIt.ico")); brand.Children.Add(new Image { Source = new Bitmap(stream), Width = 22, Height = 22 }); } catch (IOException) { }
        brand.Children.Add(new TextBlock { Foreground = Brush.Parse("#171717"), Text = "PairIt", FontSize = 17, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center }); header.Children.Add(brand); panel.Children.Add(header);
        panel.Children.Add(new TextBlock { Foreground = Brush.Parse("#171717"), Text = Environment.MachineName, FontSize = 15, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        status.FontSize = 12; status.Text = "No phones connected"; status.MinHeight = 38; panel.Children.Add(status);
        outputArea.Children.Add(new TextBlock { Text = "Audio output", FontSize = 10, Foreground = Brush.Parse("#666666") });
        phone.Content = "Phone"; computer.Content = "Computer";
        var segment = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), Height = 36 };
        Grid.SetColumn(computer, 1); segment.Children.Add(phone); segment.Children.Add(computer);
        outputArea.Children.Add(new Border { Background = Brush.Parse("#EEEEEE"), CornerRadius = new CornerRadius(12), Padding = new Thickness(3), Child = segment }); panel.Children.Add(outputArea);
        panel.Children.Add(playback);
        playback.Click+=async (_,_)=>{
            if(playbackBusy||sessions==null)return;
            bool playing=sessions.Status.ActiveReceivers==0||sessions.Status.ComputerOutput;playbackBusy=true;playback.IsEnabled=false;
            var loading=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,HorizontalAlignment=HorizontalAlignment.Center};
            loading.Children.Add(new PlaybackSpinner());loading.Children.Add(new TextBlock{Foreground=Brushes.White,Text=playing?"Resuming…":"Pausing…"});playback.Content=loading;
            try{await sessions.RequestPlaybackAsync(playing);}catch(Exception error){status.Text=error.Message;}
            finally{playbackBusy=false;UpdateButtons();}
        };
        playback.CornerRadius=new CornerRadius(12);playback.HorizontalContentAlignment=HorizontalAlignment.Center;playback.Background=Brush.Parse("#111111");playback.Foreground=Brushes.White;playback.HorizontalAlignment=HorizontalAlignment.Stretch;
        show.Content = "Pair a phone";
        var actions = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), Height = 36 };
        Grid.SetColumn(disconnect, 1); actions.Children.Add(show); actions.Children.Add(disconnect); panel.Children.Add(actions);
        disconnect.Click += async (_, _) => { await ChangeAsync(() => sessions!.ConfigureAsync(sessions.CurrentSettings with { SharingEnabled = false, MicrophoneEnabled = false })); UpdateButtons(); };
        foreach (var button in new[] { phone, computer, show, disconnect, settings }) {
            button.Background = Brushes.Transparent; button.Foreground = Brushes.Black; button.CornerRadius = new CornerRadius(9);
            button.Padding = new Thickness(6, 3); button.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        panel.Children.Add(updateNotice);
        updateNotice.Click += (_, _) => { if (releaseUpdates?.Available is { } update) OpenUrl(update.Url); };
        if (startServices) {
            releaseUpdates = new ReleaseUpdates();
            updateTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(15) };
            updateTimer.Tick += async (_, _) => await releaseUpdates.CheckAsync();
            updateTimer.Start();
            releaseUpdates.Changed += () => Dispatcher.UIThread.Post(UpdateReleaseNotice);
            Activated += async (_, _) => { if (!closing) await releaseUpdates.CheckAsync(); };
        }
        Content = ScrollContent(panel);
        outputs.SelectionChanged += (_, _) => UpdateButtons();
        addresses.SelectionChanged += (_, _) => HideCode();
        phone.Click += async (_, _) => await ChangeAsync(() => sessions!.SetComputerOutputAsync(false));
        computer.Click += async (_, _) => await ChangeAsync(() => sessions!.SetComputerOutputAsync(true));
        show.Click += async (_, _) => { try { await PairAsync(); } catch { status.Text = "Could not show pairing code."; } };
        Opened += (_, _) => {
            FitToScreen(this);
            if (startServices && !Program.SmokeTest) {
                try { tray = new DesktopTray(this); } catch (Exception) { /* The taskbar remains available without tray support. */ }
            }
        };
        if (startServices) Opened += async (_, _) => { await StartAsync(); await releaseUpdates!.CheckAsync(); };
        Closing += async (_, e) => {
            if (closed) return;
            e.Cancel = true;
            if (closing) return;
            closing = true; updateTimer?.Stop(); releaseUpdates?.Dispose(); UpdateButtons();
            try { discovery?.Dispose(); if (server != null) await server.DisposeAsync(); }
            finally { tray?.Dispose(); identity?.Dispose(); instance?.Dispose(); closed = true; Close(); }
        };
        UpdateButtons();
    }
    private void UpdateReleaseNotice()
    {
        if (closing) return;
        updateNotice.IsVisible = releaseUpdates?.Available != null;
        if (releaseUpdates?.Available is { } update)
            updateNotice.Content = new TextBlock { Foreground = Brush.Parse("#171717"), Text = $"Update available · {update.Version} ↗", TextWrapping = TextWrapping.Wrap };
    }
    private static ScrollViewer ScrollContent(Control content) => new() {
        Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto
    };
    private static Window CreateDialog(string title, double width, double height)
    {
        var dialog = new Window {
            Title = title, Width = width, Height = height, MinWidth = 280, MinHeight = 220,
            CanResize = true, ShowInTaskbar = false, Background = Brushes.White, Foreground = Brush.Parse("#171717"),
            RequestedThemeVariant = ThemeVariant.Light, WindowStartupLocation = WindowStartupLocation.CenterOwner
        };
        dialog.Opened += (_, _) => FitToScreen(dialog);
        return dialog;
    }
    private static void FitToScreen(Window window)
    {
        var screen = window.Screens.ScreenFromWindow(window);
        if (screen == null) return;
        // WorkingArea is physical pixels; dimensions are logical pixels. Leave room for decorations.
        var width = Math.Max(160, screen.WorkingArea.Width / window.RenderScaling - 32);
        var height = Math.Max(140, screen.WorkingArea.Height / window.RenderScaling - 64);
        window.MinWidth = Math.Min(window.MinWidth, width);
        window.MinHeight = Math.Min(window.MinHeight, height);
        window.MaxHeight = height;
        window.Width = Math.Min(window.Width, width);
        window.Height = Math.Min(window.Height, height);
        // CenterOwner can calculate a position using the pre-clamped dialog size.
        // Window managers differ in whether they correct that position afterward.
        var area = screen.WorkingArea;
        var right = Math.Max(area.X, area.Right - (int)Math.Ceiling(window.Width * window.RenderScaling));
        var bottom = Math.Max(area.Y, area.Bottom - (int)Math.Ceiling(window.Height * window.RenderScaling));
        var safeLeft = Math.Min(right, area.X + (int)(8 * window.RenderScaling));
        var safeTop = Math.Min(bottom, area.Y + (int)(24 * window.RenderScaling));
        window.Position = new PixelPoint(Math.Clamp(window.Position.X, safeLeft, right),
            Math.Clamp(window.Position.Y, safeTop, bottom));
    }
    private static TextBlock Label(string text) => new() { Foreground = Brush.Parse("#171717"), Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 14 };
    private static TextBlock Heading(string text) => new() { Foreground = Brush.Parse("#171717"), Text = text, FontSize = 12, FontWeight = FontWeight.SemiBold };
    private async Task StartAsync()
    {
        try
        {
            identity = LocalIdentity.LoadOrCreate();
            var lockPath = Path.Combine(LocalIdentity.DirectoryPath, "running.lock");
            if (new FileInfo(lockPath).LinkTarget != null) throw new IOException();
            instance = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            sessions = new DesktopSessions(new LinuxAudioEndpoints());
            sessions.StatusChanged += value => Dispatcher.UIThread.Post(() => {
                if (closing) return;
                status.Text = ConnectionStatus(value);
                UpdateButtons();
            });
            sessions.PairingAcknowledged += () => Dispatcher.UIThread.Post(() => { status.Text = ConnectionStatus(sessions.Status); pairingWindow?.Close(); UpdateButtons(); });
            server = new RelayServer(identity.Certificate, identity.Token, sessions); server.Start();
            discovery = new ComputerDiscovery(identity.Pin, "linux", Environment.MachineName);
            RefreshAddresses();
            await RefreshAsync();
            if (Program.SmokeTest) {
                Console.WriteLine("PASS: Linux graphical companion opened.");
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) }; timer.Tick += (_, _) => { timer.Stop(); Close(); }; timer.Start();
            }
        }
        catch { status.Text = "Could not start. Check that PairIt is not already running, port 5002 is free, and your PairIt data directory is private. See START-HERE.txt."; }
        UpdateButtons();
    }
    private void RefreshAddresses()
    {
        var previous = addresses.SelectedItem as string;
        var available = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
            .Select(a => a.Address.ToString()).Distinct().ToArray();
        addresses.ItemsSource = available;
        addresses.SelectedItem = available.Contains(previous) ? previous : available.FirstOrDefault();
    }
    private string ConnectionStatus(DesktopStatus value) => value.MicrophoneActive ? "Phone microphone active" : sessions?.CurrentSettings.MicrophoneEnabled == true ? "Ready for phone microphone" : value.Receivers > 0
        ? (value.Receivers == 1 ? "Your phone" : $"{value.Receivers} phones") + "\n" +
          (value.ActiveReceivers > 0 && !value.ComputerOutput ? "Listening" : value.ComputerOutput ? "Computer output" : "Paused")
        : "No phones connected";
    private async Task RefreshAsync()
    {
        await ChangeAsync(async () => {
            var previous = (outputs.SelectedItem as AudioOutput)?.Monitor;
            var items = (await PulseAudio.ListAsync()).Where(o => !o.IsRelay).ToArray(); outputs.ItemsSource = items;
            outputs.SelectedItem = items.FirstOrDefault(o => o.Monitor == previous) ?? items.FirstOrDefault();
            status.Text = items.Length == 0 ? "Choose an audio source in Settings." : sessions == null ? "No phones connected" : ConnectionStatus(sessions.Status);
        });
    }
    private async Task ChangeAsync(Func<Task> action)
    {
        if (busy || closing) return;
        busy = true; UpdateButtons();
        try { await action(); }
        catch { status.Text = "Audio action failed. Install pulseaudio-utils, check your PipeWire/PulseAudio session and selected output, then try again."; }
        finally { busy = false; UpdateButtons(); }
    }
    private void UpdateButtons()
    {
        var running = sessions?.CurrentSettings.SharingEnabled == true;
        var ready = sessions?.Status.Receivers > 0;
        ExpandForPlayback(ready);
        playback.IsVisible=ready;playback.IsEnabled=ready&&!playbackBusy&&!closing;
        if(!playbackBusy)playback.Content=sessions?.Status.ActiveReceivers>0&&sessions?.Status.ComputerOutput!=true?"Pause audio":"Resume audio";
        outputArea.IsVisible = ready; disconnect.IsVisible = ready || running || sessions?.CurrentSettings.MicrophoneEnabled == true;
        Grid.SetColumnSpan(show, disconnect.IsVisible ? 1 : 2);
        disconnect.IsEnabled = !busy && !closing && sessions != null;
        phone.IsEnabled = computer.IsEnabled = !busy && !closing && running;
        var onComputer = sessions?.Status.ComputerOutput == true;
        phone.Background = onComputer ? Brush.Parse("#EEEEEE") : Brush.Parse("#111111");
        phone.Foreground = onComputer ? Brushes.Black : Brushes.White;
        computer.Background = onComputer ? Brush.Parse("#111111") : Brush.Parse("#EEEEEE");
        computer.Foreground = onComputer ? Brushes.White : Brushes.Black;
        show.IsEnabled = !busy && !closing && server != null;
    }
    internal void ExpandForPlayback(bool connected)
    {
        if (connected == expandedForPlayback) return;
        expandedForPlayback = connected;
        Height = Math.Min(MaxHeight, connected ? 350 : 230);
        FitToScreen(this);
    }
    private async Task PairAsync()
    {
        if (sessions == null || identity == null) return;
        if (pairingWindow != null) { pairingWindow.Activate(); return; }
        RefreshAddresses();
        if (addresses.SelectedItem is not string) { status.Text = "Connect this computer to your local network, then try again."; return; }
        if (!sessions.CurrentSettings.SharingEnabled) {
            if (outputs.SelectedItem is not AudioOutput selected) { status.Text = "Choose an audio source in Settings."; return; }
            await ChangeAsync(() => sessions.ConfigureAsync(new DesktopSettings(SourceEndpointId: selected.Monitor, SharingEnabled: true)));
            if (!sessions.CurrentSettings.SharingEnabled) return;
        }
        if (pairingWindow != null) { pairingWindow.Activate(); return; }
        var dialog = CreatePairingWindow(identity.PairingCode, addresses.ItemsSource?.Cast<string>() ?? [], addresses.SelectedIndex);
        pairingWindow = dialog;
        dialog.Closed += (_, _) => pairingWindow = null;
        dialog.Show(this);
    }
    internal Window CreatePairingWindow(Func<string, string> codeForHost, IEnumerable<string> hosts, int selectedIndex)
    {
        var dialog = CreateDialog("Pair a phone", 360, 460);
        var choices = new ComboBox { Foreground = Brush.Parse("#171717"), Background = Brush.Parse("#EEEEEE"), ItemsSource = hosts, HorizontalAlignment = HorizontalAlignment.Stretch };
        var picture = new Image { Width = 220, Height = 220 };
        Bitmap? bitmap = null;
        choices.SelectionChanged += (_, _) => {
            if (choices.SelectedItem is not string host) return;
            using var data = QRCodeGenerator.GenerateQrCode(codeForHost(host), QRCodeGenerator.ECCLevel.M);
            using var renderer = new PngByteQRCode(data); bitmap?.Dispose(); bitmap = new Bitmap(new MemoryStream(renderer.GetGraphic(6))); picture.Source = bitmap;
        };
        var copyCode = new Button { Content = "Copy pairing code", MinHeight = 40, HorizontalContentAlignment = HorizontalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Stretch, Background = Brush.Parse("#111111"), Foreground = Brushes.White, CornerRadius = new CornerRadius(12) };
        copyCode.Click += async (_, _) => { try { if (choices.SelectedItem is string host && Clipboard != null) await Clipboard.SetTextAsync(codeForHost(host)); } catch { copyCode.Content = "Clipboard unavailable"; } };
        dialog.Content = ScrollContent(new StackPanel { Margin = new Thickness(18), Spacing = 12, Children = { Label("Open PairIt on your phone and scan this code."), choices, picture, copyCode, new TextBlock { Foreground = Brush.Parse("#171717"), Text = "Keep this code private.", FontSize = 10 }, PhoneDownloads() } });
        choices.SelectedIndex = selectedIndex;
        dialog.Closed += (_, _) => bitmap?.Dispose();
        return dialog;
    }
    private void HideCode() { pairingWindow?.Close(); }
    internal void ShowSettings()
    {
        if (settingsWindow != null) { settingsWindow.Activate(); return; }
        settingsWindow = CreateSettingsWindow();
        settingsWindow.Closed += (_, _) => settingsWindow = null;
        settingsWindow.Show(this);
    }
    internal Window CreateSettingsWindow()
    {
        var dialog = CreateDialog("Settings", 380, 450);
        var choices = new ComboBox { Foreground = Brush.Parse("#171717"), Background = Brush.Parse("#EEEEEE"), ItemsSource = outputs.ItemsSource, SelectedItem = outputs.SelectedItem, HorizontalAlignment = HorizontalAlignment.Stretch };
        choices.SelectionChanged += (_, _) => { outputs.SelectedItem = choices.SelectedItem; };
        var apply = new Button { Foreground = Brushes.Black, Background = Brush.Parse("#EEEEEE"), Content = "Apply source" };
        apply.Click += async (_, _) => { if (choices.SelectedItem is AudioOutput selected && sessions != null) await ChangeAsync(() => sessions.ConfigureAsync(sessions.CurrentSettings with { SourceEndpointId = selected.Monitor })); };
        var reload = new Button { Foreground = Brushes.Black, Background = Brush.Parse("#EEEEEE"), Content = "Refresh outputs" }; reload.Click += async (_, _) => { await RefreshAsync(); choices.ItemsSource = outputs.ItemsSource; choices.SelectedItem = outputs.SelectedItem; };
        var update = new Button { Foreground = Brushes.Black, Background = Brush.Parse("#EEEEEE"), Content = "Check for updates" };
        var downloadUpdate = new Button { Foreground = Brushes.Black, Background = Brush.Parse("#EEEEEE"), Content = "Download update ↗", IsVisible = releaseUpdates?.Available != null };
        downloadUpdate.Click += (_, _) => { if (releaseUpdates?.Available is { } available) OpenUrl(available.Url); };
        var updateStatus = new TextBlock { Foreground = Brush.Parse("#171717"), Text = releaseUpdates?.Status ?? "", FontSize = 11, TextWrapping = TextWrapping.Wrap };
        update.Click += async (_, _) => {
            if (releaseUpdates == null) return;
            update.IsEnabled = false; update.Content = "Checking…";
            try { await releaseUpdates.CheckAsync(force: true); }
            finally {
                update.IsEnabled = true;
                update.Content = "Check for updates"; downloadUpdate.IsVisible = releaseUpdates.Available != null;
                updateStatus.Text = releaseUpdates.Status;
            }
        };
        var virtualOutputs = (outputs.ItemsSource as IEnumerable<AudioOutput> ?? []).Where(o => o.Virtual).ToArray();
        var micOutputs = new ComboBox { Foreground = Brush.Parse("#171717"), Background = Brush.Parse("#EEEEEE"), ItemsSource = virtualOutputs, SelectedIndex = virtualOutputs.Length > 0 ? 0 : -1, HorizontalAlignment = HorizontalAlignment.Stretch };
        var mic = new Button { Foreground = Brushes.Black, Background = Brush.Parse("#EEEEEE"), Content = sessions?.CurrentSettings.MicrophoneEnabled == true ? "Turn off phone microphone" : "Use phone microphone" };
        mic.Click += async (_, _) => {
            if (sessions == null) return;
            if (sessions.CurrentSettings.MicrophoneEnabled) {
                await ChangeAsync(() => sessions.ConfigureAsync(sessions.CurrentSettings with { MicrophoneEnabled = false }));
            } else if (micOutputs.SelectedItem is AudioOutput selected) {
                await ChangeAsync(() => sessions.ConfigureAsync(sessions.CurrentSettings with {
                    SharingEnabled = false, MicrophoneEnabled = true, MicrophoneEndpointId = selected.Name, VirtualEndpointConfirmed = true }));
            }
            mic.Content = sessions.CurrentSettings.MicrophoneEnabled ? "Turn off phone microphone" : "Use phone microphone";
        };
        mic.IsEnabled = virtualOutputs.Length > 0 || sessions?.CurrentSettings.MicrophoneEnabled == true;
        dialog.Content = ScrollContent(new StackPanel { Margin = new Thickness(14), Spacing = 8, Children = { Label("Audio source"), choices, new WrapPanel { Children = { apply, reload } }, Label("Phone sends this output to your phone. Computer restores playback to this computer."), Heading("Phone microphone"), micOutputs, mic, new TextBlock { Foreground = Brush.Parse("#171717"), Text = "Choose a virtual sink, then its monitor as the microphone in your calling app. Start capture explicitly on your phone. See START-HERE.txt for setup.", TextWrapping = TextWrapping.Wrap, FontSize = 11 }, update, updateStatus, downloadUpdate, PhoneDownloads() } });
        return dialog;
    }
    private Control PhoneDownloads()
    {
        var row = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var android in new[] { true, false }) {
            var icon = new Avalonia.Controls.Shapes.Path {
                Data = Geometry.Parse(android ? "M3,11 A6,6 0 0 1 15,11 Z M5,6 L3,3 M13,6 L15,3 M6,8 L6,9 M12,8 L12,9" : "M5,2 L13,2 L13,16 L5,16 Z M8,13 L10,13"),
                Stroke = Brushes.Black, StrokeThickness = 1.5, Width = 18, Height = 18
            };
            var button = new Button { Foreground = Brush.Parse("#171717"), Background = Brush.Parse("#EEEEEE"), Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6,
                Children = { icon, new TextBlock { Foreground = Brush.Parse("#171717"), Text = android ? "Android ↗" : "iPhone ↗", FontSize = 12, VerticalAlignment = VerticalAlignment.Center } } },
                MinWidth = 118, Margin = new Thickness(0, 0, 6, 6), MinHeight = 36, CornerRadius = new CornerRadius(9) };
            var anchor = android ? "android" : "iphone";
            button.Click += (_, _) => OpenUrl("https://pairit.kartikey.xyz/downloads.html#" + anchor);
            Avalonia.Automation.AutomationProperties.SetName(button, android ? "Download PairIt for Android" : "PairIt for iPhone");
            row.Children.Add(button);
        }
        return row;
    }
    private void OpenUrl(string url)
    {
        try { var info = new System.Diagnostics.ProcessStartInfo("/usr/bin/xdg-open") { UseShellExecute = false }; info.ArgumentList.Add(url); System.Diagnostics.Process.Start(info)?.Dispose(); }
        catch { status.Text = "Open pairit.kartikey.xyz/downloads.html in your browser."; }
    }
}
