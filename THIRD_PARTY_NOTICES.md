# Third-party components

The root [MIT license](LICENSE) covers original PairIt source. Dependencies and adapted
code retain their own terms. This inventory is a navigation aid, not a replacement for
vendor licenses or a claim that every bundled binary is MIT-licensed.

| Component | Notice / source of dependency information |
| --- | --- |
| Chakra Petch font | [SIL Open Font License](design/fonts/OFL.txt); copied into applicable app packages |
| Apple-derived audio driver code | [Apple permissive notice](mac/driver/APPLE-LICENSE.txt); bundled by the driver build |
| .NET runtime / WindowsDesktop | [runtime license](windows/licenses/dotnet-10.0.15-LICENSE.txt), [WindowsDesktop license](windows/licenses/windowsdesktop-10.0.15-LICENSE.txt), [third-party notices](windows/licenses/dotnet-10.0.15-THIRD-PARTY-NOTICES.txt) |
| NAudio | [MIT notice](windows/licenses/NAudio-MIT.txt) |
| QRCoder | [notice](windows/licenses/QRCoder-LICENSE.txt) |
| Avalonia, Tmds.DBus, MicroCom | [Avalonia](linux/licenses/Avalonia-LICENSE.txt), [Tmds.DBus](linux/licenses/Tmds.DBus-LICENSE.txt), [MicroCom](linux/licenses/MicroCom-LICENSE.txt) |
| Linux native/transitive libraries, including Skia/HarfBuzz | Dependency lockfiles and `scripts/package-linux-licenses.py`; package-local `licenses/` includes upstream notices |
| Sparkle | Pinned/checksummed download in `scripts/prepare-sparkle.py`; its license is copied into the Mac app |
| Google Mobile Ads, User Messaging Platform and code scanner / Play services | SDK dependencies declared in `android/build.gradle` and `scripts/generate-ios-project.py`; their SDK/service terms apply separately from PairIt’s MIT source |

Keep notices with redistributed packages. Check transitive dependencies when updating
SDKs; do not assume this inventory substitutes for their terms. App icons are generated
by `scripts/generate-app-icons.swift`. Official branding, signing identities and service
configuration should not be presented as your fork’s identity.
