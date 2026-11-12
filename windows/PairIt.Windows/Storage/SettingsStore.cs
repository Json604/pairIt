using System.Text.Json;
using PairIt.Core;

namespace PairIt.Windows.Storage;

internal static class SettingsStore
{
    private static string FilePath => Path.Combine(LocalIdentity.DirectoryPath, "settings.json");
    public static DesktopSettings Load()
    {
        try
        {
            var value = JsonSerializer.Deserialize<DesktopSettings>(File.ReadAllText(FilePath)) ?? new();
            // Reopening the app never enables a microphone or resumes sharing.
            return value with { MicrophoneEnabled = false, SharingEnabled = false };
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    public static void Save(DesktopSettings value)
    {
        var temporary = FilePath + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value with { MicrophoneEnabled = false, SharingEnabled = false }));
        File.Move(temporary, FilePath, true);
    }
}
