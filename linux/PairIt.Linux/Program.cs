using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using PairIt.Core;

namespace PairIt.Linux;

internal static class Program
{
    public static bool SmokeTest { get; private set; }
    [STAThread]
    public static int Main(string[] args)
    {
        if (!OperatingSystem.IsLinux()) { Console.Error.WriteLine("This companion runs on Linux."); return 1; }
        if (DesktopInstaller.IsWorker(args)) return DesktopInstaller.RunWorkerAsync(args[1]).GetAwaiter().GetResult();
        SmokeTest = args.Contains("--smoke-test");
        try { return AppBuilder.Configure<App>().UsePlatformDetect().StartWithClassicDesktopLifetime(args); }
        catch { Console.Error.WriteLine("PairIt could not start. Check your graphical session and the dependencies in START-HERE.txt."); return 1; }
    }
}

public sealed class App : Application
{
    public override void Initialize()
    {
        // All PairIt surfaces are light; resolve templates/popups in the same scope.
        RequestedThemeVariant = Avalonia.Styling.ThemeVariant.Light;
        Styles.Add(new FluentTheme());
    }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop) desktop.MainWindow = new CompanionWindow();
        base.OnFrameworkInitializationCompleted();
    }
}
