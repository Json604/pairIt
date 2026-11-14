using System.Security.Cryptography;

namespace PairIt.Core;

/// <summary>User-initiated download state shared by the two desktop front ends.</summary>
public sealed class InstallerProgress : IDisposable
{
    private CancellationTokenSource? cancellation;
    public bool Busy => cancellation != null;
    public bool CanCancel { get; private set; }
    public string? Status { get; private set; } = DesktopInstaller.TakeResult();
    public event Action? Changed;

    public async Task StartOrCancelAsync(int build, Func<Task> restart)
    {
        if (Busy) { if (CanCancel) cancellation!.Cancel(); return; }
        using var operation = new CancellationTokenSource(); cancellation = operation; CanCancel = true;
        SetStatus("Preparing download…");
        try {
            await DesktopInstaller.PrepareAsync(build, message => {
                if (message == "Preparing installation…") CanCancel = false;
                SetStatus(message);
            }, operation.Token);
            await restart();
        } catch (OperationCanceledException) {
            SetStatus(operation.IsCancellationRequested ? "Download cancelled. Your current app is unchanged." : "Download timed out. Please try again.");
        } catch (CryptographicException) {
            SetStatus("Update verification failed. Nothing was installed. Please try again later.");
        } catch (InvalidOperationException error) {
            SetStatus(error.Message);
        } catch (InvalidDataException) {
            SetStatus("This update cannot be installed safely. Retry later or use the download page.");
        } catch (HttpRequestException) {
            SetStatus("Couldn’t download the update. Check your connection and try again.");
        } catch (Exception) {
            SetStatus("Couldn’t prepare this update. Check free disk space and folder access, then retry.");
        } finally {
            cancellation = null; CanCancel = false; Changed?.Invoke();
        }
    }
    public void ClearStatus() { if (!Busy) { Status = null; Changed?.Invoke(); } }
    private void SetStatus(string value) { Status = value; Changed?.Invoke(); }
    public void Dispose() { if (CanCancel) cancellation?.Cancel(); }
}
