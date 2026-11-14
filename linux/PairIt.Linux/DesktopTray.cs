using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform;

namespace PairIt.Linux;

/// <summary>Optional desktop integration; the taskbar window remains usable without a tray host.</summary>
internal sealed class DesktopTray : IDisposable
{
    private readonly TrayIcon icon;
    internal DesktopTray(CompanionWindow window)
    {
        using var image = AssetLoader.Open(new Uri("avares://PairIt/PairIt.ico"));
        var menu = new NativeMenu();
        var open = new NativeMenuItem("Open PairIt");
        open.Click += (_, _) => Restore(window);
        var settings = new NativeMenuItem("Settings");
        settings.Click += (_, _) => { Restore(window); window.ShowSettings(); };
        var quit = new NativeMenuItem("Quit PairIt");
        quit.Click += (_, _) => window.Close();
        menu.Items.Add(open); menu.Items.Add(settings); menu.Items.Add(new NativeMenuItemSeparator()); menu.Items.Add(quit);
        icon = new TrayIcon { Icon = new WindowIcon(image), ToolTipText = "PairIt · Computer audio on your phone", Menu = menu, IsVisible = true };
        icon.Clicked += (_, _) => Restore(window);
        var app = Application.Current ?? throw new InvalidOperationException("Application not initialized");
        var icons = TrayIcon.GetIcons(app);
        if (icons == null) { icons = new TrayIcons(); TrayIcon.SetIcons(app, icons); }
        icons.Add(icon);
    }
    private static void Restore(Window window)
    {
        window.Show(); window.WindowState = WindowState.Normal; window.Activate();
    }
    public void Dispose()
    {
        if (Application.Current is { } app) TrayIcon.GetIcons(app)?.Remove(icon);
        icon.Dispose();
    }
}
