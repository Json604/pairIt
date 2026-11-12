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
    private readonly TextBlock status = Label("Getting ready…"), listeners = Label("No phones connected"), paired = Label("");
    private readonly Button sharing = new() { Content = "Start sharing" }, refresh = new() { Content = "Refresh outputs" };
    private readonly Button phone = new() { Content = "Phone headphones" }, computer = new() { Content = "Computer speakers" };
    private readonly Button copy = new() { Content = "Copy pairing code" }, show = new() { Content = "Show pairing code" };
    private readonly Image qr = new() { Width = 240, Height = 240, IsVisible = false };
    private LocalIdentity? identity;
    private DesktopSessions? sessions;
    private RelayServer? server;
    private FileStream? instance;
    private Bitmap? qrBitmap;
    private bool busy, closing, closed;

    public CompanionWindow()
    {
        Title = "PairIt · Linux preview"; Width = 500; Height = 740; MinWidth = 400; MinHeight = 480;
        Background = Brush.Parse("#FFF8F2"); Foreground = Brush.Parse("#252321");
        var panel = new StackPanel { Margin = new Thickness(26), Spacing = 14 };
        panel.Children.Add(new TextBlock { Text = "PairIt", FontSize = 32, FontWeight = FontWeight.SemiBold });
        panel.Children.Add(Label("Your computer. Your phone. Your headphones."));
        panel.Children.Add(status); panel.Children.Add(listeners); panel.Children.Add(paired);
        panel.Children.Add(Heading("COMPUTER AUDIO SOURCE")); panel.Children.Add(outputs); panel.Children.Add(refresh); panel.Children.Add(sharing);
        panel.Children.Add(Heading("LISTEN ON"));
        panel.Children.Add(new WrapPanel { Orientation = Orientation.Horizontal, Children = { phone, computer } });
        panel.Children.Add(Label("Switching keeps phones connected. Local computer output stays unchanged; use a virtual output for silent speakers. Paused phones resume from the phone."));
        panel.Children.Add(Heading("PAIR A PHONE")); panel.Children.Add(addresses);
        panel.Children.Add(Label("Keep both devices on the same Wi-Fi. Scan the code or paste the pairing link in PairIt on your phone."));
        panel.Children.Add(new WrapPanel { Children = { show, copy } }); panel.Children.Add(qr);
        panel.Children.Add(Label("Keep the pairing code private. Up to four phones can listen."));
        var downloads = new Button { Content = "Get phone apps" };
        downloads.Click += (_, _) => OpenUrl("https://pairit.kartikey.xyz/downloads.html"); panel.Children.Add(downloads);
        var updates = new Button { Content = "Check for updates" };
        updates.Click += async (_, _) => {
            updates.IsEnabled = false;
            try { var entry = await ReleaseUpdates.CheckAsync();
                if (entry != null) { status.Text = "An update is available. Opening official downloads."; OpenUrl(entry); }
                else status.Text = "No newer Linux build was found.";
            } catch { status.Text = "Could not check for updates. Try again when online."; }
            finally { updates.IsEnabled = true; }
        };
        panel.Children.Add(updates);
        panel.Children.Add(Label("Linux preview · PipeWire/PulseAudio · No video compensation or automatic player pause. Closing this window stops sharing."));
        Content = new ScrollViewer { Content = panel };
        outputs.SelectionChanged += (_, _) => UpdateButtons();
        addresses.SelectionChanged += (_, _) => HideCode();
        refresh.Click += async (_, _) => await RefreshAsync();
        sharing.Click += async (_, _) => await ChangeAsync(async () => {
            if (sessions == null) return;
            var enabled = !sessions.CurrentSettings.SharingEnabled;
            if (enabled && outputs.SelectedItem is not AudioOutput) return;
            await sessions.ConfigureAsync(new DesktopSettings(SourceEndpointId: (outputs.SelectedItem as AudioOutput)?.Monitor, SharingEnabled: enabled));
        });
        phone.Click += async (_, _) => await ChangeAsync(() => sessions!.SetComputerOutputAsync(false));
        computer.Click += async (_, _) => await ChangeAsync(() => sessions!.SetComputerOutputAsync(true));
        show.Click += (_, _) => { if (qr.IsVisible) HideCode(); else ShowCode(); };
        copy.Click += async (_, _) => {
            try { if (identity != null && addresses.SelectedItem is string host && Clipboard != null) {
                await Clipboard.SetTextAsync(identity.PairingCode(host)); status.Text = "Pairing code copied. Keep it private.";
            } } catch { status.Text = "Clipboard unavailable. Use the QR code instead."; }
        };
        Opened += async (_, _) => await StartAsync();
        Closing += async (_, e) => {
            if (closed) return;
            e.Cancel = true;
            if (closing) return;
            closing = true; UpdateButtons();
            try { if (server != null) await server.DisposeAsync(); }
            finally { identity?.Dispose(); instance?.Dispose(); qrBitmap?.Dispose(); closed = true; Close(); }
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
                status.Text = value.Message;
                listeners.Text = $"{value.Receivers}/4 phones connected · {(value.ComputerOutput ? 0 : value.ActiveReceivers)} listening";
                UpdateButtons();
            });
            sessions.PairingAcknowledged += () => Dispatcher.UIThread.Post(() => { paired.Text = "✓ Phone paired. Start audio on your phone when ready."; HideCode(); });
            server = new RelayServer(identity.Certificate, identity.Token, sessions); server.Start();
            addresses.ItemsSource = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses).Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(a => a.Address.ToString()).Distinct().ToArray();
            addresses.SelectedIndex = 0;
            await RefreshAsync();
            if (Program.SmokeTest) {
                Console.WriteLine("PASS: Linux graphical companion opened.");
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) }; timer.Tick += (_, _) => { timer.Stop(); Close(); }; timer.Start();
            }
        }
        catch { status.Text = "Could not start. Check that PairIt is not already running, port 5002 is free, and your PairIt data directory is private. See START-HERE.txt."; }
        UpdateButtons();
    }
    private async Task RefreshAsync()
    {
        await ChangeAsync(async () => {
            var previous = (outputs.SelectedItem as AudioOutput)?.Monitor;
            var items = await PulseAudio.ListAsync(); outputs.ItemsSource = items;
            outputs.SelectedItem = items.FirstOrDefault(o => o.Monitor == previous) ?? items.FirstOrDefault();
            status.Text = items.Count == 0 ? "No audio outputs found. Start your audio session, then refresh." : "Choose the output your apps use, then start sharing.";
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
        sharing.Content = running ? "Stop sharing" : "Start sharing";
        sharing.IsEnabled = !busy && !closing && sessions != null && (running || outputs.SelectedItem is AudioOutput);
        outputs.IsEnabled = refresh.IsEnabled = !busy && !closing && !running;
        phone.IsEnabled = computer.IsEnabled = !busy && !closing && running;
        phone.FontWeight = sessions?.Status.ComputerOutput != true ? FontWeight.Bold : FontWeight.Normal;
        computer.FontWeight = sessions?.Status.ComputerOutput == true ? FontWeight.Bold : FontWeight.Normal;
        copy.IsEnabled = show.IsEnabled = !closing && server != null && addresses.SelectedItem is string;
    }
    private void ShowCode()
    {
        if (identity == null || addresses.SelectedItem is not string host) return;
        using var data = QRCodeGenerator.GenerateQrCode(identity.PairingCode(host), QRCodeGenerator.ECCLevel.M);
        using var code = new PngByteQRCode(data);
        qrBitmap?.Dispose(); qrBitmap = new Bitmap(new MemoryStream(code.GetGraphic(6)));
        qr.Source = qrBitmap; qr.IsVisible = true; show.Content = "Hide pairing code";
    }
    private void HideCode() { qr.IsVisible = false; qr.Source = null; qrBitmap?.Dispose(); qrBitmap = null; show.Content = "Show pairing code"; UpdateButtons(); }
    private void OpenUrl(string url)
    {
        try { var info = new System.Diagnostics.ProcessStartInfo("/usr/bin/xdg-open") { UseShellExecute = false }; info.ArgumentList.Add(url); System.Diagnostics.Process.Start(info)?.Dispose(); }
        catch { status.Text = "Open pairit.kartikey.xyz/downloads.html in your browser."; }
    }
}
