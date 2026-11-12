# PairIt Windows preview

PairIt sends a chosen Windows audio output over encrypted local networking to
up to four paired phones. Its two tabs are **Audio relay** and **Listen together**.
This preview focuses on computer audio relay and shared listening; phone
microphone controls are not offered. Audio is streamed
in memory; PairIt creates no audio recordings and uses no cloud audio server.

This is an unsigned, self-contained x64 feature preview. It has not been run on
a Windows machine. A successful build and synthetic checks do not establish
Windows UI, WASAPI, firewall, speech quality or acoustic synchronization.
ARM64 is not offered or verified in this preview.

## Start and pair

1. Extract the complete `PairIt-Windows` folder from the ZIP and launch
   `PairIt.exe` inside it. Keep the DLLs,
   runtime files, `licenses` folder and this README together. No installation,
   administrator access, driver installation or .NET runtime download is needed.
2. Open PairIt using its icon in the Windows notification area. The window opens
   on first launch; closing the small window keeps the companion in the tray.
   **Exit PairIt** in the tray menu closes connections and audio workers.
3. Open **Listen together** and choose a reachable address on your local network.
   Copy the private pairing code and paste it into PairIt on your phone. Clear
   the clipboard after pairing. The code contains credentials; do not post it.
4. If Windows asks about the firewall, allow PairIt on the trusted private
   network you intend to use. PairIt listens on TCP 5002. It does not open
   firewall rules automatically. Do not expose or port-forward it to the Internet.
5. Under **Audio relay**, select the actual render output used by your apps
   and click **Start sharing**. Capture starts only after a paired receiver
   connects. Choose Bluetooth, speaker or wired audio explicitly on the phone.

Address selection is manual in this Windows preview; it does not advertise
Bonjour discovery. Phones remember the address and pin. If the address changes,
update the phone's manual host or pair using this computer's new address. The
TLS identity stays the same. Multiple interfaces are listed by name; PairIt
does not infer USB merely because a cable is attached.

## Windows audio limits

WASAPI loopback captures the selected **render** endpoint. Local speakers keep
playing when apps play there. PairIt never changes default Windows devices or
silently mutes physical speakers. To avoid local playback, choose a separately
installed virtual render output for your apps and select the same source here.
This routing is a user choice in Windows, not an automatic PairIt change.

The preview accepts 44.1 or 48 kHz mono/stereo mixes, converts float32 or signed
PCM16/24/32 to stereo PCM16, and keeps the mix sample rate. Other formats report
an unsupported-format error; use Windows sound settings to select a supported
format. It does not fabricate timestamps, reinterpret sample rates or fall back
to another device. Protected content may be unavailable to loopback capture.
Removing/changing the endpoint ends sharing; select and start it again.

Windows does not have the PairIt Mac HAL driver's downstream video compensation.
Bluetooth delay still exists, and output devices can have different acoustic
latencies. Simultaneous listening is not a claim of synchronized multiroom
audio.

## Phone/computer handoff

With an updated phone app that negotiates handoff support, switching to phone
audio holds that phone's relay while keeping its existing encrypted connection
for controls. A held phone still occupies one of the four listener slots. Other
active listeners keep receiving the same audio. Older phone versions retain
their existing explicit controls; preview 5 alone cannot add phone-side handoff.

When the last active listener switches to phone audio, PairIt makes one best
effort Pause request to Windows' current media session through the public
Global System Media Transport Controls API (GSMTC). Only apps that publish
compatible media controls can respond. Games, calls, some desktop players,
protected media and browser tabs may be unsupported or ambiguous. Windows
chooses its current session; the API does not identify which session plays
through the selected loopback endpoint. Multiple players are not all paused.

If Pause succeeds and that same session reports Paused, PairIt can offer a
return when it later reports Playing. An updated Android app accepts the offer
only while its control connection survives and its output, audio focus, call
and ad checks allow it. The iPhone app currently requires an explicit return to
computer audio; background suspension prevents a reliable automatic return.
Windows events do not reveal whether Play came from a person, autoplay or
another remote control. Session/media changes cancel the offer. A phone Pause
does not arm automatic return, and an output change never requests player pause.

PairIt never sends an automatic Play command, switches Windows to speakers,
changes default devices or changes system volume. WASAPI loopback itself does
not mute local audio: if an app rejects or ignores Pause, it may keep playing
on the output it already used. Pause that app yourself if needed. An already
issued native command may finish after cancellation; its stale result cannot
reopen relay or acquire a new handoff. New or resuming listeners wait up to two
seconds for an unresolved player command to actually finish before capture can
start. If it is still pending, that activation closes and must be retried after
the player responds. Timing out does not forget the command or issue Play.
Starting another listener, Stop all,
disconnect, source failure, Windows lock/suspend/logoff or Exit clears ownership.
Locking Windows preserves ordinary audio, cancels an armed handoff offer and
suppresses player control until unlock. Unlock does not rearm an old intent.
Sharing requires an explicit start after restart, logoff or suspend.

Handoff is a best effort preview, not universal Bluetooth multipoint. Windows
runtime/player support, physical route changes and long background sessions
still need validation. The capability flag advertises an available API; a
separate status flag reports the owned session's currently observed Paused state.

## USB setup

USB uses the exact same authenticated, pinned TLS protocol through an
OS-provided network. It is not USB Audio Class or an ADB/debugging connection.

- **Android → Windows:** connect USB and enable USB tethering in Android's
  network settings. Enable the compatible network adapter on Windows if needed.
- **iPhone → Windows:** Personal Hotspot requires cellular/carrier support,
  Apple Devices or iTunes, USB accessory approval and trust. Hotspot can change
  the computer's Internet route and cause unrelated cellular data usage.
- Refresh PairIt's addresses, select the USB network's Windows IPv4 address,
  and set that address as the phone's explicit manual computer host. Preserve
  the existing pin/token. Verify the actual route before calling it USB.

Use **Local network** as the transport description unless the route is confirmed.
VPNs, simultaneous Wi-Fi/USB and interface changes need real-device validation.
Clear the manual host on the phone when returning to another route.

## Identity, privacy and recovery

The per-installation certificate/private key and token are stored under
`%LOCALAPPDATA%\PairIt\identity.dpapi`, protected with current-user Windows DPAPI.
For Windows TLS, it is imported into an OS-protected current-user key container
without `PersistKeySet`; normal certificate disposal releases that temporary
import. The DPAPI file remains the durable identity. Normal restarts reuse it.
An unreadable identity fails startup instead
of silently rotating trust. Endpoint settings contain no pairing credential.
Never distribute the identity file, include it in build artifacts or delete it
as a routine troubleshooting step. Replacing it would invalidate existing pins.

No audio, credentials, remote installation identifiers or arbitrary incoming
control text are logged. The companion has no ad SDK. The phone app's own
advertising/privacy disclosures still apply. For connection failures, check the
selected local address, private-network firewall permission, source selection
and phone pairing. New clients cannot evict unrelated healthy receivers.

## Build and verification

Source requires the exactly pinned **.NET SDK 10.0.403**. NAudio.Wasapi and
NAudio.Core are locked at **2.2.1** with NuGet integrity hashes. Run from the
workspace root:

```sh
bash scripts/build-windows.sh
```

On Windows use `powershell -File scripts/build-windows.ps1`. `PAIRIT_DOTNET` can
select the SDK executable. Both scripts use checked-in dependency lockfiles;
updating them requires the explicit `--update-lock` / `-UpdateLock` option.
Builds, caches and publish results go only under
`artifacts/feature-preview/windows/` by default; `PAIRIT_WINDOWS_OUTPUT_DIR`
selects an isolated publish folder. Preview 5 uses
`artifacts/simple-listening/windows/win-x64/`. The scripts also run an in-memory,
synthetic-source TLS integration executable; it never opens a microphone or
real audio device. Handoff checks use synthetic media sessions to cover token
replays, delayed completion, shared-listener isolation and parked admission.
They do not exercise GSMTC on Windows. There are no unit tests.

The application targets Windows API build 19041 or later (Windows 10 2004+),
x64, with the .NET 10 runtime bundled. This is an API/build minimum, not a claim
that every Windows version is currently supported by Microsoft or validated by
PairIt. Use a supported Windows installation and complete the runtime acceptance
on a real Windows machine before distribution.

Technical references: [WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording),
[capture timestamp contract](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer),
[NAudio 2.2.1](https://github.com/naudio/NAudio/tree/v2.2.1),
[Windows GSMTC](https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager),
[Apple Personal Hotspot](https://support.apple.com/en-us/111785),
[Android tethering](https://support.google.com/android/answer/9059108).
