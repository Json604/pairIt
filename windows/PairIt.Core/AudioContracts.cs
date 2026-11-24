namespace PairIt.Core;

public sealed record SourcePacket(int Rate, int Frames, long FirstFrameNanoseconds, byte[] StereoPcm16, bool Discontinuity = false);

public interface ISystemAudioSource : IAsyncDisposable
{
    uint? ComputerVolume => null;
    // True only when captured PCM is taken before ComputerVolume is applied (Windows
    // loopback). Then a STATS VOLUME2 phone owns its volume and computer volume keys
    // move it; otherwise the computer volume would attenuate that phone twice.
    bool VolumeIndependentCapture => false;
    Task StartAsync(Action<SourcePacket> received, Action<string> failed, CancellationToken cancellation);
}

public interface IMicrophoneSink : IAsyncDisposable
{
    void Write(ReadOnlySpan<byte> monoPcm16);
    Task FlushAsync(CancellationToken cancellation);
}

public interface IAudioEndpoints
{
    // A routed source may need to hold its silent output while a connected phone is paused.
    bool KeepCaptureWhilePaused => false;
    ISystemAudioSource CreateSource(string endpointId);
    Task<IMicrophoneSink> OpenMicrophoneSinkAsync(string endpointId, CancellationToken cancellation);
}

public sealed record DesktopSettings(string? SourceEndpointId = null, string? MicrophoneEndpointId = null,
    bool VirtualEndpointConfirmed = false, bool MicrophoneEnabled = false, bool SharingEnabled = false);

public sealed record DesktopStatus(int Receivers, int ActiveReceivers, bool Capturing, bool MicrophoneActive, string Message, bool ComputerOutput = false, string PhoneNames = "Phone");

public enum DesktopPhoneState { Listening, Paused, Connected }

// One connected phone. Level is the phone's own media volume (0..1000) when it sent STATS VOLUME2.
// StopsOnDisconnect: an updated phone (STATS CONTROLS2) stops instead of reconnecting.
public sealed record DesktopPhone(Guid Id, string Name, DesktopPhoneState State, int? Level, bool StopsOnDisconnect, string? InstallationId = null);
