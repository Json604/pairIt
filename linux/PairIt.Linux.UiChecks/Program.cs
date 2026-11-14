using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using Avalonia.VisualTree;
using PairIt.Linux;

internal static class Program
{
    public static string Output = ".";
    public static bool Dark;
    [STAThread]
    public static int Main(string[] args)
    {
        Output = args[0]; Dark = args.Contains("--dark");
        Directory.CreateDirectory(Output);
        return AppBuilder.Configure<CheckApp>().UsePlatformDetect().StartWithClassicDesktopLifetime(args);
    }
}

internal sealed class CheckApp : Application
{
    public override void Initialize() { RequestedThemeVariant = Program.Dark ? ThemeVariant.Dark : ThemeVariant.Light; Styles.Add(new FluentTheme()); }
    public override void OnFrameworkInitializationCompleted()
    {
        var desktop = (IClassicDesktopStyleApplicationLifetime)ApplicationLifetime!;
        var window = new CompanionWindow(startServices: false);
        desktop.MainWindow = window;
        window.Opened += async (_, _) => {
            try {
                await Task.Delay(200);
                CheckWindow(window, "main");
                // Exercise the real controls in a connected layout without opening an audio/network session.
                foreach (var name in new[] { "outputArea", "playback", "disconnect" })
                    ((Control)typeof(CompanionWindow).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!).IsVisible = true;
                foreach (var name in new[] { "phone", "computer", "playback", "disconnect", "show" })
                    ((Button)typeof(CompanionWindow).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!).IsEnabled = true;
                Grid.SetColumnSpan((Button)typeof(CompanionWindow).GetField("show", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!, 1);
                ((TextBlock)typeof(CompanionWindow).GetField("status", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!).Text = "Four phones\nListening";
                await Task.Delay(100);
                CheckWindow(window, "connected");
                var pairing = window.CreatePairingWindow(_ => "PAIRIT-UI-TEST-NOT-A-REAL-PAIRING-CODE", new[] { "192.0.2.10" }, 0);
                pairing.Show(window);
                await Task.Delay(200);
                CheckWindow(pairing, "pairing");
                pairing.Close();
                var settings = window.CreateSettingsWindow();
                settings.Show(window);
                await Task.Delay(200);
                CheckWindow(settings, "settings");
                settings.Height = 280;
                await Task.Delay(100);
                var scroll = settings.GetVisualDescendants().OfType<ScrollViewer>().First();
                Require(scroll.Extent.Height > scroll.Viewport.Height, "Short screens must scroll settings rather than clip controls");
                scroll.Offset = new Vector(0, scroll.Extent.Height);
                await Task.Delay(100);
                Snapshot(settings, "settings-short");
                settings.Close();
                Console.WriteLine("PASS: Linux UI contrast, scroll reachability, and window placement (" + (Program.Dark ? "dark" : "light") + " host theme).");
                desktop.Shutdown(0);
            } catch (Exception error) { Console.Error.WriteLine(error); desktop.Shutdown(1); }
        };
        base.OnFrameworkInitializationCompleted();
    }
    private static void CheckWindow(Window window, string name)
    {
        Snapshot(window, name);
        Console.WriteLine($"{name}: scale={window.RenderScaling}, size={window.Bounds.Size}, position={window.Position}");
        Require(window.ActualThemeVariant == ThemeVariant.Light, name + " light surface must not inherit dark control resources");
        Require(window.CanResize, name + " must remain resizable for accessibility");
        Require(window.GetVisualDescendants().OfType<ScrollViewer>().Any(), name + " must support content overflow");
        var screen = window.Screens.ScreenFromWindow(window)!;
        Require(screen.WorkingArea.Contains(window.Position), name + " must open on screen");
        Require(window.Bounds.Width * window.RenderScaling <= screen.WorkingArea.Width && window.Bounds.Height * window.RenderScaling <= screen.WorkingArea.Height, name + " must fit the scaled work area");
        foreach (var label in window.GetVisualDescendants().OfType<TextBlock>().Where(x => x.IsEffectivelyVisible && x.FindAncestorOfType<Button>() == null)) {
            if (label.Foreground is ISolidColorBrush brush) Require(brush.Color.R < 180 || brush.Color.G < 180 || brush.Color.B < 180, name + " has pale text on a light surface: " + label.Text);
        }
    }
    private static void Snapshot(Window window, string name)
    {
        using var bitmap = new RenderTargetBitmap(new PixelSize((int)window.Bounds.Width, (int)window.Bounds.Height));
        bitmap.Render(window);
        bitmap.Save(Path.Combine(Program.Output, name + ".png"), PngBitmapEncoderOptions.Default);
    }
    private static void Require(bool value, string reason) { if (!value) throw new Exception(reason); }
}
