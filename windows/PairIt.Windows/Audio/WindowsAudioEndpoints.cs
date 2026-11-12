using NAudio.CoreAudioApi;
using PairIt.Core;

namespace PairIt.Windows.Audio;

public sealed record RenderEndpoint(string Id, string Name, bool IsVirtualCable)
{
    public override string ToString() => Name;
}

public sealed class WindowsAudioEndpoints : IAudioEndpoints
{
    public static IReadOnlyList<RenderEndpoint> List()
    {
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<RenderEndpoint>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (device) result.Add(new(device.ID, device.FriendlyName, IsVirtualCable(device.FriendlyName)));
        }
        return result.OrderBy(endpoint => endpoint.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }

    // Endpoint display names cannot establish security. Restrict the preview to
    // known virtual-cable families AND require the user's explicit confirmation.
    // There is deliberately no default-device or physical-speaker fallback.
    public static bool IsVirtualCable(string name) => new[] { "CABLE Input", "VB-Audio", "VoiceMeeter", "Virtual Audio Cable" }
        .Any(marker => name.Contains(marker, StringComparison.OrdinalIgnoreCase));

    public ISystemAudioSource CreateSource(string endpointId) => new WasapiSystemSource(endpointId);

    public async Task<IMicrophoneSink> OpenMicrophoneSinkAsync(string endpointId, CancellationToken cancellation)
    {
        var sink = new WasapiMicrophoneSink(endpointId);
        try { await sink.OpenAsync(cancellation).ConfigureAwait(false); return sink; }
        catch { await sink.DisposeAsync().ConfigureAwait(false); throw; }
    }
}
