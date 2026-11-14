using System.Net.NetworkInformation;
using System.Net.Sockets;
using Avalonia;
using Avalonia.Controls;
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
    private readonly ComboBox outputs = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox addresses = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
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
    private Window? pairingWindow;
    private readonly StackPanel outputArea = new() { Spacing = 7 };
    private readonly Button disconnect = new() { Content = "Disconnect" };

    public CompanionWindow()
    {
        Title = "PairIt - AudioRelay"; Width = 300; Height = 350; CanResize = false;
        Background = Brush.Parse("#FAFAFA"); Foreground = Brush.Parse("#171717");
        var panel = new StackPanel { Margin = new Thickness(14, 10, 14, 12), Spacing = 10 };
        var header = new DockPanel { Height = 28, LastChildFill = false };
        var settings = new Button { Content = "⚙", Width = 32, Height = 28, Padding = new Thickness(0) };
        settings.Click += (_, _) => ShowSettings(); DockPanel.SetDock(settings, Dock.Right); header.Children.Add(settings);
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7, VerticalAlignment = VerticalAlignment.Center };
        try { using var stream = Avalonia.Platform.AssetLoader.Open(new Uri("avares://PairIt/PairIt.ico")); brand.Children.Add(new Image { Source = new Bitmap(stream), Width = 22, Height = 22 }); } catch (IOException) { }
        brand.Children.Add(new TextBlock { Text = "PairIt", FontSize = 17, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center }); header.Children.Add(brand); panel.Children.Add(header);
        panel.Children.Add(new TextBlock { Text = Environment.MachineName, FontSize = 15, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
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
            loading.Children.Add(new PlaybackSpinner());loading.Children.Add(new TextBlock{Text=playing?"Resuming…":"Pausing…"});playback.Content=loading;
            try{await sessions.RequestPlaybackAsync(playing);}catch(Exception error){status.Text=error.Message;}
            finally{playbackBusy=false;UpdateButtons();}
        };
        playback.Background=Brush.Parse("#111111");playback.Foreground=Brushes.White;playback.HorizontalAlignment=HorizontalAlignment.Stretch;
        show.Content = "Pair a phone";
        var actions = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), Height = 36 };
        Grid.SetColumn(disconnect, 1); actions.Children.Add(show); actions.Children.Add(disconnect); panel.Children.Add(actions);
        disconnect.Click += async (_, _) => { await ChangeAsync(() => sessions!.ConfigureAsync(sessions.CurrentSettings with { SharingEnabled = false, MicrophoneEnabled = false })); UpdateButtons(); };
        foreach (var button in new[] { phone, computer, show, disconnect, settings }) {
            button.Background = Brushes.Transparent; button.Foreground = Brushes.Black; button.CornerRadius = new CornerRadius(9);
            button.Padding = new Thickness(6, 3); button.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        Content = panel;
        outputs.SelectionChanged += (_, _) => UpdateButtons();
        addresses.SelectionChanged += (_, _) => HideCode();
        phone.Click += async (_, _) => await ChangeAsync(() => sessions!.SetComputerOutputAsync(false));
        computer.Click += async (_, _) => await ChangeAsync(() => sessions!.SetComputerOutputAsync(true));
        show.Click += async (_, _) => { try { await PairAsync(); } catch { status.Text = "Could not show pairing code."; } };
        Opened += async (_, _) => await StartAsync();
        Closing += async (_, e) => {
            if (closed) return;
            e.Cancel = true;
            if (closing) return;
            closing = true; UpdateButtons();
            try { discovery?.Dispose(); if (server != null) await server.DisposeAsync(); }
            finally { identity?.Dispose(); instance?.Dispose(); closed = true; Close(); }
        };
        UpdateButtons();
    }
    private static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 14 };
    private static TextBlock Heading(string text) => new() { Text = text, FontSize = 12, FontWeight = FontWeight.SemiBold };
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
            var items = await PulseAudio.ListAsync(); outputs.ItemsSource = items;
            outputs.SelectedItem = items.FirstOrDefault(o => o.Monitor == previous) ?? items.FirstOrDefault();
            status.Text = items.Count == 0 ? "Choose an audio source in Settings." : sessions == null ? "No phones connected" : ConnectionStatus(sessions.Status);
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
        playback.IsVisible=ready;playback.IsEnabled=ready&&!playbackBusy&&!closing;
        if(!playbackBusy)playback.Content=sessions?.Status.ActiveReceivers>0&&sessions?.Status.ComputerOutput!=true?"Pause audio":"Resume audio";
        outputArea.IsVisible = ready; disconnect.IsVisible = ready || running || sessions?.CurrentSettings.MicrophoneEnabled == true;
        disconnect.IsEnabled = !busy && !closing && sessions != null;
        phone.IsEnabled = computer.IsEnabled = !busy && !closing && running;
        var onComputer = sessions?.Status.ComputerOutput == true;
        phone.Background = onComputer ? Brush.Parse("#EEEEEE") : Brush.Parse("#111111");
        phone.Foreground = onComputer ? Brushes.Black : Brushes.White;
        computer.Background = onComputer ? Brush.Parse("#111111") : Brush.Parse("#EEEEEE");
        computer.Foreground = onComputer ? Brushes.White : Brushes.Black;
        show.IsEnabled = !busy && !closing && server != null;
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
        var dialog = new Window { Title = "Pair a phone", Width = 300, Height = 400, CanResize = false, Background = Brushes.White, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        pairingWindow = dialog;
        var choices = new ComboBox { ItemsSource = addresses.ItemsSource, HorizontalAlignment = HorizontalAlignment.Stretch };
        var picture = new Image { Width = 220, Height = 220 };
        Bitmap? bitmap = null;
        choices.SelectionChanged += (_, _) => {
            if (choices.SelectedItem is not string host) return;
            using var data = QRCodeGenerator.GenerateQrCode(identity.PairingCode(host), QRCodeGenerator.ECCLevel.M);
            using var renderer = new PngByteQRCode(data); bitmap?.Dispose(); bitmap = new Bitmap(new MemoryStream(renderer.GetGraphic(6))); picture.Source = bitmap;
        };
        var copyCode = new Button { Content = "Copy pairing code", HorizontalAlignment = HorizontalAlignment.Stretch, Background = Brush.Parse("#111111"), Foreground = Brushes.White, CornerRadius = new CornerRadius(12) };
        copyCode.Click += async (_, _) => { try { if (choices.SelectedItem is string host && Clipboard != null) await Clipboard.SetTextAsync(identity.PairingCode(host)); } catch { copyCode.Content = "Clipboard unavailable"; } };
        dialog.Content = new StackPanel { Margin = new Thickness(14), Spacing = 8, Children = { choices, picture, copyCode, new TextBlock { Text = "Keep this code private.", FontSize = 10 }, PhoneDownloads() } };
        choices.SelectedIndex = addresses.SelectedIndex;
        dialog.Closed += (_, _) => { bitmap?.Dispose(); pairingWindow = null; };
        dialog.Show(this);
    }
    private void HideCode() { pairingWindow?.Close(); }
    private void ShowSettings()
    {
        var dialog = new Window { Title = "Settings", Width = 330, Height = 520, CanResize = false, Background = Brushes.White, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var choices = new ComboBox { ItemsSource = outputs.ItemsSource, SelectedItem = outputs.SelectedItem, HorizontalAlignment = HorizontalAlignment.Stretch };
        choices.SelectionChanged += (_, _) => { outputs.SelectedItem = choices.SelectedItem; };
        var apply = new Button { Content = "Apply source" };
        apply.Click += async (_, _) => { if (choices.SelectedItem is AudioOutput selected && sessions != null) await ChangeAsync(() => sessions.ConfigureAsync(sessions.CurrentSettings with { SourceEndpointId = selected.Monitor })); };
        var reload = new Button { Content = "Refresh outputs" }; reload.Click += async (_, _) => { await RefreshAsync(); choices.ItemsSource = outputs.ItemsSource; choices.SelectedItem = outputs.SelectedItem; };
        var update = new Button { Content = "Check for updates" }; update.Click += async (_, _) => { try { var link = await ReleaseUpdates.CheckAsync(); if (link != null) OpenUrl(link); else update.Content = "No update available"; } catch { update.Content = "Check failed. Try again."; } };
        var virtualOutputs = (outputs.ItemsSource as IEnumerable<AudioOutput> ?? []).Where(o => o.Virtual).ToArray();
        var micOutputs = new ComboBox { ItemsSource = virtualOutputs, SelectedIndex = virtualOutputs.Length > 0 ? 0 : -1, HorizontalAlignment = HorizontalAlignment.Stretch };
        var mic = new Button { Content = sessions?.CurrentSettings.MicrophoneEnabled == true ? "Turn off phone microphone" : "Use phone microphone" };
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
        dialog.Content = new StackPanel { Margin = new Thickness(14), Spacing = 8, Children = { Label("Audio source"), choices, new WrapPanel { Children = { apply, reload } }, Label("Local speakers stay on. Use a virtual output to silence them."), Heading("Phone microphone"), micOutputs, mic, new TextBlock { Text = "Choose a virtual sink, then its monitor as the microphone in your calling app. Start capture explicitly on your phone. See START-HERE.txt for setup.", TextWrapping = TextWrapping.Wrap, FontSize = 11 }, update, PhoneDownloads() } };
        dialog.Show(this);
    }
    private Control PhoneDownloads()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var android in new[] { true, false }) {
            var icon = new Avalonia.Controls.Shapes.Path {
                Data = Geometry.Parse(android ? "M3,11 A6,6 0 0 1 15,11 Z M5,6 L3,3 M13,6 L15,3 M6,8 L6,9 M12,8 L12,9" : "M5,2 L13,2 L13,16 L5,16 Z M8,13 L10,13"),
                Stroke = Brushes.Black, StrokeThickness = 1.5, Width = 18, Height = 18
            };
            var button = new Button { Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6,
                Children = { icon, new TextBlock { Text = android ? "Android ↗" : "iPhone ↗", FontSize = 12, VerticalAlignment = VerticalAlignment.Center } } },
                Width = 128, MinHeight = 36, CornerRadius = new CornerRadius(9) };
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
