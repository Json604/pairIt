using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using PairIt.Core;
using PairIt.Windows.Storage;

namespace PairIt.Windows;

internal sealed class TrayApplication : ApplicationContext
{
    private readonly CompanionForm form;
    private readonly NotifyIcon tray;
    private readonly DesktopSessions sessions;
    private readonly Icon icon;
    private bool exiting;

    public TrayApplication(LocalIdentity identity, DesktopSessions sessions)
    {
        this.sessions = sessions;
        icon = CreateIcon();
        form = new CompanionForm(sessions, identity) { Icon = icon };
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open PairIt - AudioRelay", null, (_, _) => form.Reveal());
        menu.Items.Add("Stop all audio", null, async (_, _) => await form.StopAllAsync());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit PairIt - AudioRelay", null, async (_, _) => await ExitAsync());
        tray = new NotifyIcon { Text = "PairIt - AudioRelay", Icon = icon, Visible = true, ContextMenuStrip = menu };
        tray.MouseClick += (_, args) => { if (args.Button == MouseButtons.Left) { if (form.Visible) form.Hide(); else form.Reveal(); } };
        sessions.StatusChanged += StatusChanged;
        sessions.PairingAcknowledged += PairingAcknowledged;
        SystemEvents.PowerModeChanged += PowerChanged;
        SystemEvents.SessionSwitch += SessionChanged;
        form.Reveal();
    }

    private void StatusChanged(DesktopStatus status) => form.UpdateStatus(status);
    private void PairingAcknowledged()
    {
        if (form.IsDisposed || !form.IsHandleCreated) return;
        try
        {
            form.BeginInvoke(() =>
            {
                if (!exiting && !form.IsDisposed)
                {
                    form.ShowPaired();
                }
            });
        }
        catch (InvalidOperationException) { /* Shutdown raced the pairing acknowledgment. */ }
    }
    private async void PowerChanged(object sender, PowerModeChangedEventArgs args)
    {
        if (args.Mode == PowerModes.Suspend) await StopForSystemEventAsync(preserveSharing: true);
    }
    private async void SessionChanged(object sender, SessionSwitchEventArgs args)
    {
        if (args.Reason is SessionSwitchReason.SessionLogoff) await StopForSystemEventAsync();
        if (args.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionUnlock)
        {
            // Locking preserves ordinary audio, but a previously armed offer
            // and later PARK commands cannot arm player control until unlock.
            try { await sessions.SetMediaHandoffSuppressedAsync(args.Reason == SessionSwitchReason.SessionLock); }
            catch { /* Shutdown may already be draining the same resources. */ }
        }
    }
    private async Task StopForSystemEventAsync(bool preserveSharing = false)
    {
        try {
            // End live capture before sleep, but retain the user's sharing choice.
            // The listener can admit a fresh authenticated phone after wake; an
            // explicit Stop still clears SharingEnabled and is never undone here.
            var current = sessions.CurrentSettings;
            await sessions.ConfigureAsync(current with { MicrophoneEnabled = false, SharingEnabled = preserveSharing && current.SharingEnabled });
        }
        catch { /* Shutdown may already be draining the same resources. */ }
    }

    private async Task ExitAsync()
    {
        if (exiting) return;
        exiting = true;
        await form.StopAllAsync();
        tray.Visible = false;
        form.ExitRequested = true;
        form.Close();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            sessions.StatusChanged -= StatusChanged;
            sessions.PairingAcknowledged -= PairingAcknowledged;
            SystemEvents.PowerModeChanged -= PowerChanged;
            SystemEvents.SessionSwitch -= SessionChanged;
            tray.Visible = false;
            tray.ContextMenuStrip?.Dispose();
            tray.Dispose();
            form.Dispose();
            icon.Dispose();
        }
        base.Dispose(disposing);
    }

    private static Icon CreateIcon()
    {
        var applicationIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        if (applicationIcon != null) return applicationIcon;
        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var accent = new Pen(PairItAppearance.Orange, 3.5f);
        graphics.DrawArc(accent, 6, 4, 20, 24, 180, 180);
        graphics.DrawLine(accent, 6, 16, 6, 26);
        graphics.DrawLine(accent, 26, 16, 26, 26);
        var handle = bitmap.GetHicon();
        try { using var borrowed = Icon.FromHandle(handle); return (Icon)borrowed.Clone(); }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
