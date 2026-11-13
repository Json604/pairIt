#!/usr/bin/env python3
"""Generate app-local documents and public publishing pages from one release profile."""
from pathlib import Path
import html, json, re
from urllib.parse import urlparse
ROOT=Path(__file__).resolve().parent.parent
PROFILE=ROOT/'release/google-play/release.json'

def validate(profile):
    missing=[]
    for key in ['app_name','publisher_name','support_email','privacy_url','mac_download_url']:
        if not profile.get(key):missing.append(key)
    if not profile.get('public_name_confirmed'):missing.append('public_name_confirmed')
    if profile.get('support_email') and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',profile['support_email']):missing.append('valid support_email')
    for key in ['website_url','privacy_url','mac_download_url']:
        value=profile.get(key,'')
        if value and (urlparse(value).scheme!='https' or not urlparse(value).netloc):missing.append('HTTPS '+key)
    return missing

def page(title,text,name):
    paragraphs=[]
    for paragraph in text.strip().split('\n\n'):
        if paragraph.startswith('## '):paragraphs.append('<h2>'+html.escape(paragraph[3:])+'</h2>')
        else:paragraphs.append('<p>'+html.escape(paragraph).replace('\n','<br>')+'</p>')
    return '<!doctype html>\n<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><title>'+html.escape(title+' — '+name)+'</title><style>body{margin:0;background:#f5f8fc;color:#102c4a;font:17px/1.65 system-ui,sans-serif}main{max-width:720px;margin:48px auto;padding:32px}h1{font-size:36px;letter-spacing:-1px;line-height:1.15}h2{font-size:21px;margin-top:40px}p{color:#405a71}a{color:#1261bb}nav{margin-bottom:36px;font-size:14px}footer{margin-top:48px;border-top:1px solid #dce7f0;padding-top:24px;font-size:14px}@media(max-width:600px){main{margin:16px auto;padding:24px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto}}</style><main><nav>'+html.escape(name)+' · <a href="support.html">Help</a> · <a href="privacy.html">Privacy</a></nav><h1>'+html.escape(title)+'</h1>'+''.join(paragraphs)+'<footer>No tracking scripts, cookies or forms are used on this page.</footer></main></html>\n'

def main():
    p=json.loads(PROFILE.read_text());name=p['app_name'];publisher=p.get('publisher_name','');email=p.get('support_email','')
    privacy=f'''Effective date: {p['effective_date']}

This policy explains how {name} handles information when you listen to computer audio on your Android phone or iPhone, alone or with other listeners.'''
    if publisher:privacy+=f' {publisher} publishes the app.'
    privacy+='''

## Audio stays between your devices

The phone app receives live audio from the Mac, Windows or Linux computer you pair. The connection is encrypted and authenticated with the computer’s certificate and pairing credentials. The publisher does not receive your audio, and PairIt does not save audio recordings. Audio is temporarily buffered in memory for playback. Operational timing and connection statistics are exchanged with your paired computer to keep playback working; they are not sent to a publisher server.

## Earlier feature previews

Older feature-preview builds offered a standalone phone microphone. In those builds capture required an explicit Start action, permission and acceptance by the paired computer. PairIt did not save recordings; a receiving computer app could record or transmit the input under its own settings. Current two-feature builds remove that mode and its microphone permission.

## Information stored on this device

The app stores the paired computer’s local address, authentication credentials, and headphone timing preferences in app-private storage. Android backup and device-transfer rules exclude this data. On iPhone, pairing credentials use this-device-only Keychain storage; preferences use the app’s local settings. Pairing credentials allow access to your shared computer audio; keep the pairing code private. The audio feature does not require an account. Advertising data is described below.

## Nearby discovery and sharing

PairIt uses local-network discovery to list computers on Connect and other PairIt phones on Together. Computer announcements contain a display name, platform and public certificate fingerprint, never the private pairing code. Phone presence is advertised only while Together is visible, using a temporary identifier and a generic phone name. Other devices on the same network can see these announcements. Discovery alone does not authenticate a new computer. Android and iPhone can request pairing from a nearby Mac; compare the code on both devices and approve on the Mac. Windows and Linux use a QR code or pasted pairing code.

Tapping a nearby phone opens the system share sheet with the public PairIt download link. You choose the recipient and send action. PairIt does not send the link or pairing credentials to that phone automatically. Phones without PairIt do not appear in its nearby list; use Share app and the system’s available sharing options.

## Permissions and device access

Nearby devices access is requested on Android 12 and later only for Bluetooth output. Speaker and wired playback do not need this permission. Local networking connects to the computer you paired, including supported USB network links. A foreground media service and temporary wake/Wi-Fi locks support background playback. Notification permission keeps playback controls visible while listening or paused; this idle notification does not require continuous streaming. Disconnect removes it. PairIt does not request microphone, camera, contacts, photos, storage or location access on Android. Choose Scan QR code inside PairIt to open Google Play services’ scanner, or paste a pairing code. Scanner images are processed on the phone; Google states that it does not store the images or scan results. PairIt receives only the decoded code and verifies the computer’s pinned certificate before saving and connecting. Pasted pairing codes require confirmation. The scanner needs Google Play services and may need an initial module download; pasting works without it. The Android scanner also sends Google technical device and app information, identifiers, performance and error metrics, configuration information, and scanner usage events for diagnostics and usage analytics. This data is encrypted in transit. Google states that ML Kit does not transfer this listed data to third parties. This scanner processing is separate from advertising consent choices.

On iPhone, local network access discovers and connects to your paired computer. Camera access is used only if you choose the in-app QR scanner; you can paste a pairing code instead. Background audio support keeps an explicitly started audio session working. PairIt does not request microphone, contacts, photos or location access on iPhone.

## Advertising and privacy choices

Both phone apps are supported by Google AdMob banner ads. Android keeps its banner visible behind normal dialogs. A preloaded video or image interstitial is eligible at each verified foreground connection before audio starts; there is no connection cooldown. An App Open ad is eligible during Android app opening only when at least 30 minutes has passed since the last full-screen ad. An opening ad and an automatic connection ad are not shown back-to-back. iPhone also preloads connection ads without a local connection cooldown and uses a separate 30-minute limit for app-opening ads. Playback waits until a connection ad closes. Unavailable ads are skipped after a bounded wait, and late ads never interrupt listening. Ads are not shown on the lock screen or during background playback. Banners are hidden during scanning, full-screen ads, privacy-consent changes and while the app is in the background. Ads are separate from the local audio connection. Google does not receive your relayed audio or pairing credentials from this app. The Google Mobile Ads SDK can collect and share your IP address (which can indicate approximate location), app and ad interactions, diagnostic information, and device or account identifiers, including the Android advertising ID where available, for advertising, analytics and fraud prevention. This data is encrypted in transit. Google’s policy is available at https://policies.google.com/privacy and its partner-site explanation at https://policies.google.com/technologies/partner-sites.

Where required, Google’s User Messaging Platform presents consent choices before ads are requested. Revisit available choices in Settings → Ad privacy choices. Your choices and region can affect whether personalized, non-personalized, limited or no ads are served. Android settings let you reset or delete your advertising ID. Advertising identifiers and consent settings are handled separately from pairing data; Forget this computer does not erase data held by Google. Contact Google through its privacy controls about that data. The publisher does not set Google’s retention periods. Builds configured with Google’s designated test ads do not earn advertising revenue. Production-configured builds use the publisher’s ad units, subject to consent and Google’s approval.

The iPhone app requests non-personalized ads, disables the SDK’s publisher first-party ID and permission-based coarse-location collection, and does not ask for App Tracking Transparency authorization or access to IDFA. Non-personalized ads can still use data for measurement, security and ad delivery. IP-derived approximate location may still be processed. iPhone banner sound starts muted and can be changed in Settings. Banners are hidden during scanning, full-screen flows and while the app is in the background.

## Diagnostics and support

Diagnostics contain technical playback and connection information. They remain within your devices unless you choose to copy and share them. A support email is composed in your chosen email app and is sent only when you send it. Pairing credentials and audio recordings are not attached automatically. If you contact support, the publisher receives the email and information you choose to send, uses it to answer your request, and retains it only as needed to handle the request and applicable record-keeping obligations. Do not include your pairing code.

## Removing your information

Choose Settings → Connection & pairing → Forget this computer to stop playback and remove this Android app’s pairing and saved timing preferences. Clearing Android app storage or uninstalling also removes the app’s local data. This does not revoke copies of the same computer pairing code on other devices or remove data stored on the computer. There is no online app account to delete. Stop relay playback with Disconnect in the app or Android notification. A small amount of audio already in a network or output buffer may finish while the remote endpoint is being stopped.

On iPhone, open the computer pairing screen from Settings and choose Forget this computer to remove the stored pairing credential. Do this before uninstalling if you want to remove the Keychain entry, since uninstalling alone may leave it behind.

## Update checks

PairIt periodically checks for available releases while the app is in use. Google Play installations use Google Play’s update service. Other supported builds request a small public release list hosted on GitHub over HTTPS. GitHub receives ordinary web-request information, including your IP address; PairIt does not attach audio, pairing credentials, a device identifier, or your installed version. Version and signing-certificate comparisons happen on your device. The latest available update may be cached locally so the reminder survives an offline launch. Choosing Get update opens the official store or GitHub release page. Downloads and installation remain under your control. GitHub’s privacy statement is at https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement.

## Other services

Google Play, Apple’s App Store, Android, iOS, your device manufacturer and your email provider may process store, device, crash or support-email information under their own policies and your settings. These platform services are separate from this app’s local audio connection.

## Children and changes

The app is a general audio utility and is not designed for children. The publisher does not knowingly collect children’s personal information through the app. If this policy changes, the updated version and effective date will be available here and inside the app.'''
    if email:privacy+=f'\n\n## Contact\n\nFor privacy questions or to request deletion of support correspondence, contact {publisher or name} at {email}.'
    help_text=f'''PairIt has two features: computer audio relay and shared listening.

## Set up and pair

Install PairIt on your Mac, Windows or Linux computer and phone. Keep them on the same local Wi-Fi. On Mac, finish the one-time audio-output setup and allow system audio capture. On Windows or Linux, choose the output your apps use and start sharing; local speakers can also play. Open Pair a phone on Mac, Listen together on Windows, or Pair a phone on Linux, then Scan QR code or paste the code in the phone app. Confirm the computer’s name before saving. Keep the code private.

Scanning a valid code or tapping a saved computer verifies it before connecting. A nearby Mac can approve a new request from Android or iPhone after you compare the code on both devices. A dismissible full-screen ad may appear before audio starts. Android prepares ads ahead of time for each foreground connection, with no connection cooldown. An app-opening ad uses a separate 30-minute limit. Missing ads are skipped; they do not interrupt audio later. Background reconnection does not show an ad.

## Audio relay

Tap your paired computer or scan its QR code to connect. For a new Mac, Android and iPhone can request pairing directly: compare the code on both devices and approve on the Mac. Choose This phone to listen here, Computer to use the computer’s output, or pause to stop this phone’s relay audio. Computer audio can play on your phone/headphones or the computer speakers. Use the output selector in the computer companion or the destination control in the phone app. Switching to computer speakers keeps the pairing and control connection; choose Listen here or phone headphones to return. This destination is shared by all listeners, and paused listeners stay paused. Phone output settings separately select Bluetooth headphones, the phone speaker or wired headphones. If a private output disconnects, playback stops instead of intentionally moving to the speaker. Adjust listening volume on the phone or headphones. Mac system volume keys may be unavailable with the virtual relay output; this does not mean Phone is the selected source.

Headphone play/pause pauses or resumes this phone’s live relay while keeping Computer selected. It does not change the selected source or pause other listeners. This is a live stream: the computer player can keep progressing while listening is paused, and resuming returns to live audio. Track skipping stays in the computer player. Volume and noise-control gestures remain controlled by your device/headphone manufacturer. On updated Mac companions, a connected, paused phone holds the Mac output. When the last phone disconnects or times out, the Mac restores its previous output. The computer player may continue silently; pause it manually when needed. Resume in PairIt. Disconnect ends this phone’s live connection but keeps its saved pairing. Choosing Mac speakers only changes the audio destination and keeps connected phones available. Stop sharing or Quit ends the computer’s live sessions and restores its usual output. Forget this computer removes the saved pairing.

## Listen together

Open Together to discover nearby PairIt phones. Tap a phone to open the system share sheet, or use Share app for people who have not installed PairIt. Each listener still pairs their phone with the computer using its private pairing code.

The most compatible setup uses one phone per listener. Connect each person’s Bluetooth headphones to their own phone, keep all devices on the same Wi-Fi, pair each phone with the same computer, and start audio on all of them. Up to four phones can listen. Each has its own volume and can pause independently. A slow or disconnected receiver has its own bounded connection.

Two headphones on one phone requires compatible hardware and the phone’s built-in audio-sharing feature. PairIt cannot add this to unsupported devices. On supported iPhones, Apple’s Share Audio works with compatible AirPods/Beats. Use the system output picker to select outputs before starting the relay. The separate-phone setup is the cross-platform option.

While phone output is selected, everyone receives the same stream, but different headphones can have different delays. Only one primary listener controls Mac video compensation. Shared listening is not a guarantee of perfectly synchronized sound across all outputs.

## Background controls

Android playback runs in a foreground media service and continues when the screen is locked or you use another app. The notification offers Pause/Resume, Computer output and Disconnect. Allow notifications to keep these controls available. Disconnect removes it. When playback is stopped, no wake/Wi-Fi lock or audio stream is retained just to show the switch. Android can hide notifications if you turn them off, dismiss them or stop the app. Settings → Background controls explains the controls; Quick Settings also switches sources.

On iPhone, background audio and system media controls support listening with the screen locked. Home/Lock Screen widgets provide Computer/Phone shortcuts. iOS does not provide an always-on Android-style source notification. Calls or output loss may stop playback; resume in PairIt when ready.

## Video timing and connection help

Playback uses the Reliable path. Mac video timing is estimated from the selected output; leave correction at zero initially. Some players need playback reopened after timing changes. Windows and Linux do not provide the Mac driver’s system video compensation. Bluetooth retains physical delay, especially for live audio and games.

Guest Wi-Fi isolation, VPNs and firewalls can block local connections. Connection settings accept a manual computer address while still verifying its paired certificate; clear it to restore discovery. Supported OS network links can also carry the same connection, but a USB cable alone is not a connection. Android-to-Mac USB networking is not generally supported.

## Requirements and downloads

Android 10 or later, iPhone with the supported iOS version, and a compatible Mac, Windows or Linux companion. Mac needs macOS 14.2 or later. Use the provided matching build; Windows and Linux remain previews until hardware playback testing is complete. Downloads: {p['mac_download_url']}.'''
    if email:help_text+='\n\n## Contact support\n\nEmail '+email+'. Include the app version, Android version, headphone model and steps to reproduce the issue. Never send a pairing code.'
    assets=ROOT/'android/assets';assets.mkdir(parents=True,exist_ok=True)
    (assets/'privacy.txt').write_text(privacy+'\n');(assets/'help.txt').write_text(help_text+'\n')
    site=ROOT/'release/google-play/site';site.mkdir(parents=True,exist_ok=True)
    (site/'privacy.html').write_text(page('Privacy policy',privacy,name));(site/'support.html').write_text(page('Help & companion setup',help_text,name))
    (site/'index.html').write_text(page(name,'PairIt: computer audio relay and shared listening.\n\nRequires matching companions and the documented output/network setup. Physical acceptance is pending.\n\n## Get started\n\nRead the setup guide and privacy policy using the links above.',name))
    values={key:p.get(key,'') for key in ['app_name','publisher_name','support_email','privacy_url','website_url','mac_download_url']};values['app_version']=p['version_name']
    xml=['<resources>']
    for key,value in values.items():xml.append(f'    <string name="{key}" translatable="false">'+html.escape(value).replace("'","\\'")+'</string>')
    (ROOT/'android/res/values/strings.xml').write_text('\n'.join(xml+['</resources>'])+'\n')
    listing=ROOT/'release/google-play/listing/en-US';listing.mkdir(parents=True,exist_ok=True)
    short='Computer audio on your phone. Listen together with up to four phones.'
    full=f'''{name} brings computer audio to your phone over an encrypted local connection.

AUDIO RELAY
Listen to a paired Mac, Windows or Linux computer through your phone’s Bluetooth headphones, speaker or wired headphones. Updated companions confirm pairing before audio starts. Keep your headphones connected to your phone and choose Headphones to listen here or Computer to use the computer’s output. Change the computer audio destination between phone headphones and computer speakers without losing the pairing. The destination applies to all listeners; paused listeners stay paused.

Playback keeps going when the screen is locked. Android’s notification and Quick Settings tile keep the source switch nearby. Headphone play/pause pauses or resumes your live relay without selecting Phone. Volume remains on your phone or headphones. The computer player can continue while your relay is paused; resuming returns to the live stream. Updated Mac companions hold output during phone interruptions. Compatible Windows media sessions can pause and offer return when playback resumes; other apps need manual controls. On iPhone, return through PairIt. Track changes stay in the computer player.

LISTEN TOGETHER
Pair up to four phones with the same computer. Each listener connects headphones to their own phone, then starts audio. Everyone receives the same stream, with independent volume and pause controls.

Different headphones may have different delays. Shared listening does not guarantee perfectly synchronized sound on every output. Connecting two headphones to a single phone depends on that phone’s built-in support and compatible hardware; PairIt cannot enable it universally.

LOCAL BY DESIGN
No PairIt account or cloud audio server. Your paired devices encrypt audio in transit. PairIt does not record audio or use your microphone. Scan or paste a pairing code from your own computer. Keep that code private.

The app has a banner and may show a dismissible video or image ad during a deliberate connection, before audio starts. Ads have a 30-minute app-opening frequency cap and are not guaranteed on every connection. Ad privacy choices are in Settings.

REQUIREMENTS
Android 10+, a compatible PairIt Mac, Windows or Linux companion, and a reachable local network. Mac requires macOS 14.2+, one-time audio-output setup and system-audio permission. The Windows and Linux companions are previews. Only the Mac driver provides automatic video compensation for a primary listener; Bluetooth still has physical latency.

Allow notifications to keep playback controls available. Disconnect removes it. System notification settings and Android’s app-stop controls remain in charge.'''
    if email:full+='\n\nSupport: '+email
    for filename,value in {'title.txt':name,'short-description.txt':short,'full-description.txt':full,'release-notes.txt':'Computer companions now confirm pairing before audio starts. Switch between computer speakers and phone headphones without disconnecting. Phone apps show the selected destination; paused listeners stay paused.'}.items():
        (listing/filename).write_text(value+'\n')
    assert len(name)<=30 and len(short)<=80 and len(full)<=4000
    status={'missing_publishing_fields':validate(p),'listing_characters':{'title':len(name),'short':len(short),'full':len(full)},'generated_from':str(PROFILE.relative_to(ROOT))}
    (ROOT/'release/google-play/content-status.json').write_text(json.dumps(status,indent=2)+'\n')
    print(json.dumps(status))
if __name__=='__main__':main()
