# Distributed dependencies

- **NAudio.Wasapi 2.2.1** and **NAudio.Core 2.2.1** — Mark Heath and contributors,
  MIT; see `NAudio-MIT.txt`. The NuGet versions and SHA-512 content hashes are
  fixed in `PairIt.Windows/packages.lock.json`.
- **.NET runtime and host 10.0.14** — Microsoft and contributors, MIT and included
  third-party notices; see `dotnet-10.0.14-LICENSE.txt` and
  `dotnet-10.0.14-THIRD-PARTY-NOTICES.txt`. The application is self-contained.
- **Windows Desktop runtime 10.0.14** — Microsoft and contributors;
  see `windowsdesktop-10.0.14-LICENSE.txt`.

The build uses exactly .NET SDK 10.0.403 (`windows/global.json`). SDK/reference
packs are build tools, not included as part of the app distribution. The
Windows runtime version is explicitly fixed in the desktop project.

No VB-CABLE, VoiceMeeter, Virtual Audio Cable or other virtual audio driver is
redistributed. Users install any such driver separately under its publisher's
license. Product names are used only for setup compatibility.

Upstream: https://github.com/naudio/NAudio/tree/v2.2.1 and
https://github.com/dotnet/runtime and https://github.com/dotnet/windowsdesktop.
