using PairIt.Core;

namespace PairIt.Windows.Storage;

internal static class SettingsApplication
{
    internal static async Task<bool> ApplyAsync(DesktopSessions sessions, DesktopSettings value, Action<DesktopSettings> persist)
    {
        await sessions.ConfigureAsync(value);
        // Stopping capture must not depend on a writable preferences file.
        // Persistence is best effort only after the requested state is active.
        try { persist(value); return true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }
}
