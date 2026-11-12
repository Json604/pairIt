param([switch]$UpdateLock)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$dotnetExe = if ($env:PAIRIT_DOTNET) { $env:PAIRIT_DOTNET } else { 'dotnet' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:NUGET_PACKAGES = Join-Path $projectRoot 'artifacts/feature-preview/windows/nuget'
Push-Location (Join-Path $projectRoot 'windows')
try {
    if ((& $dotnetExe --version) -ne '10.0.403') { throw 'Install the pinned .NET SDK 10.0.403.' }
    $lockArgument = if ($UpdateLock) { '--force-evaluate' } else { '--locked-mode' }
    & $dotnetExe restore PairIt.Windows/PairIt.Windows.csproj -p:RuntimeIdentifier=win-x64 -p:SelfContained=true $lockArgument
    if ($LASTEXITCODE) { throw 'Restore failed.' }
    & $dotnetExe publish PairIt.Windows/PairIt.Windows.csproj --no-restore -c Release -r win-x64 --self-contained true -o (Join-Path $projectRoot 'artifacts/feature-preview/windows/win-x64') -p:DebugType=None -p:DebugSymbols=false
    if ($LASTEXITCODE) { throw 'Publish failed.' }
    & $dotnetExe restore PairIt.ProtocolCheck/PairIt.ProtocolCheck.csproj $lockArgument
    if ($LASTEXITCODE) { throw 'Protocol-check restore failed.' }
    & $dotnetExe run --project PairIt.ProtocolCheck/PairIt.ProtocolCheck.csproj --no-restore -c Release
    if ($LASTEXITCODE) { throw 'Synthetic protocol check failed.' }
    Write-Output 'Built Windows x64 preview. Hardware, tray, firewall and acoustic acceptance remain separate checks.'
}
finally { Pop-Location }
