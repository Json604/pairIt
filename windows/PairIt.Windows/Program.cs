using PairIt.Core;
using PairIt.Windows.Audio;
using PairIt.Windows.Storage;

namespace PairIt.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var singleInstance = new Mutex(true, @"Local\PairIt.Windows.Companion", out var created);
        if (!created)
        {
            MessageBox.Show("PairIt is already running. Open it from the notification area.", "PairIt", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        try
        {
            using var identity = LocalIdentity.LoadOrCreate();
            var sessions = new DesktopSessions(new WindowsAudioEndpoints(), new WindowsMediaHandoff());
            var server = new RelayServer(identity.Certificate, identity.Token, sessions);
            try
            {
                server.Start();
                using var application = new TrayApplication(identity, sessions);
                Application.Run(application);
            }
            finally { server.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
        }
        catch
        {
            // Avoid displaying paths, identity contents or an untrusted exception.
            MessageBox.Show("PairIt could not start. Check that TCP port 5002 is available and your local PairIt identity can be opened by this Windows account. Do not delete the identity to troubleshoot; that would invalidate pairing.",
                "PairIt could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
