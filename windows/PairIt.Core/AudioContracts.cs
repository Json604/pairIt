namespace PairIt.Core;

public sealed record SourcePacket(int Rate, int Frames, long FirstFrameNanoseconds, byte[] StereoPcm16, bool Discontinuity = false);

public interface ISystemAudioSource : IAsyncDisposable
{
    uint? ComputerVolume => null;
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

public sealed record DesktopStatus(int Receivers, int ActiveReceivers, bool Capturing, bool MicrophoneActive, string Message, bool ComputerOutput = false);
