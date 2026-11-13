#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project; rerun when adding source files."""
from pathlib import Path
import hashlib
import json
import os
import re
root = Path(__file__).resolve().parent.parent
project = root / 'ios/AudioRelay.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
release = json.loads((root / 'release/apple/release.json').read_text())
# Preserve an already configured Xcode team when regenerating source membership.
existing = (project/'project.pbxproj').read_text() if (project/'project.pbxproj').exists() else ''
teams = set(re.findall(r'DEVELOPMENT_TEAM = "([A-Z0-9]+)";', existing))
team = os.environ.get('PAIRIT_APPLE_TEAM', next(iter(teams)) if len(teams) == 1 else '')
admob = release['admob']
if not re.fullmatch(r'ca-app-pub-\d{16}~\d{10}', admob['app_id']) or not re.fullmatch(r'ca-app-pub-\d{16}/\d{10}', admob['banner_id']):
    raise SystemExit('Invalid iOS AdMob identifiers')

def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def q(value): return '"' + str(value).replace('"', '\\"') + '"'
objects=[]
def add(name, body):
    key=ident(name); objects.append(f'\t\t{key} = {{ {body} }};'); return key
sources = [str(p.relative_to(root/'ios')) for p in sorted((root/'ios/AudioRelay').glob('*.swift'))] + ['../apple/RelayStyle.swift', '../apple/ReleaseUpdates.swift']
resources = ['AudioRelay/Assets.xcassets','AudioRelay/PrivacyInfo.xcprivacy'] + ['../design/fonts/' + name for name in ['ChakraPetch-Regular.ttf','ChakraPetch-SemiBold.ttf','OFL.txt']]
refs=[]; builds=[]; resources_build=[]
for path in sources+resources+['AudioRelay/Info.plist']:
    kind='sourcecode.swift' if path.endswith('.swift') else 'folder.assetcatalog' if path.endswith('.xcassets') else 'file' if path.endswith('.ttf') else 'text' if path.endswith('.txt') else 'text.html' if path.endswith('.html') else 'text.xml'
    ref=add(path,f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";'); refs.append(ref)
    if path.endswith('Info.plist'): continue
    build=add('build:'+path,f'isa = PBXBuildFile; fileRef = {ref};')
    (builds if path in sources else resources_build).append(build)
app=add('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = "Audio Relay.app"; sourceTree = BUILT_PRODUCTS_DIR;')
products=add('products',f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
main=add('main',f'isa = PBXGroup; children = ({",".join(refs+[products])},); sourceTree = "<group>";')
phase=add('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
rphase=add('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources_build)},); runOnlyForDeploymentPostprocessing = 0;')
packages=[]; package_products=[]; package_builds=[]
for slug, version, product_name in [('swift-package-manager-google-mobile-ads','13.12.0','GoogleMobileAds'), ('swift-package-manager-google-user-messaging-platform','3.1.0','GoogleUserMessagingPlatform')]:
    package=add('package:'+slug, f'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/googleads/{slug}.git"; requirement = {{kind = exactVersion; version = {version}; }};'); packages.append(package)
    product_ref=add('package-product:'+slug, f'isa = XCSwiftPackageProductDependency; package = {package}; productName = {product_name};'); package_products.append(product_ref)
    package_builds.append(add('package-build:'+slug, f'isa = PBXBuildFile; productRef = {product_ref};'))
fphase=add('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(package_builds)},); runOnlyForDeploymentPostprocessing = 0;')
projectconfigs=[]; targetconfigs=[]
for name in ['Debug','Release']:
    settings={'ALWAYS_SEARCH_USER_PATHS':'NO','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'targeted','GCC_C_LANGUAGE_STANDARD':'gnu17','DEBUG_INFORMATION_FORMAT':'dwarf' if name=='Debug' else 'dwarf-with-dsym','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
    if name=='Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'; settings['ONLY_ACTIVE_ARCH']='YES'
    config=add('project:'+name,'isa = XCBuildConfiguration; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'}; name = '+name+';'); projectconfigs.append(config)
    settings={'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':release['build_number'],'MARKETING_VERSION':release['version_name'],'DEVELOPMENT_TEAM':team,'GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'AudioRelay/Info.plist','PRODUCT_BUNDLE_IDENTIFIER':'dev.bluetoothswitch.iosrelay','PRODUCT_NAME':'Audio Relay','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','TARGETED_DEVICE_FAMILY':'1','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'}
    settings['PAIRIT_ADMOB_APP_ID'] = 'ca-app-pub-3940256099942544~1458002511' if name == 'Debug' else admob['app_id']
    settings['PAIRIT_ADMOB_BANNER_ID'] = 'ca-app-pub-3940256099942544/2435281174' if name == 'Debug' else admob['banner_id']
    settings['PAIRIT_ADMOB_INTERSTITIAL_ID'] = 'ca-app-pub-3940256099942544/4411468910' if name == 'Debug' else admob.get('interstitial_id', '')
    settings['PAIRIT_ADMOB_APP_OPEN_ID'] = 'ca-app-pub-3940256099942544/5575463023' if name == 'Debug' else admob.get('app_open_id', '')
    settings['OTHER_LDFLAGS'] = '$(inherited) -ObjC'
    config=add('target:'+name,'isa = XCBuildConfiguration; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'}; name = '+name+';'); targetconfigs.append(config)
pconfigs=add('projectconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(projectconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tconfigs=add('targetconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(targetconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
widgetref=add('widget:source','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "RelayWidget/RelayWidget.swift"; sourceTree = "<group>";')
widgetprivacy=add('widget:privacy','isa = PBXFileReference; lastKnownFileType = text.xml; path = "RelayWidget/PrivacyInfo.xcprivacy"; sourceTree = "<group>";')
widgetplist=add('widget:plist','isa = PBXFileReference; lastKnownFileType = text.xml; path = "RelayWidget/Info.plist"; sourceTree = "<group>";')
widgetbuild=add('widget:sourcebuild',f'isa = PBXBuildFile; fileRef = {widgetref};')
widgetprivacybuild=add('widget:privacybuild',f'isa = PBXBuildFile; fileRef = {widgetprivacy};')
widgetproduct=add('widget:product','isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = RelayWidget.appex; sourceTree = BUILT_PRODUCTS_DIR;')
widgetsources=add('widget:sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({widgetbuild},); runOnlyForDeploymentPostprocessing = 0;')
widgetresources=add('widget:resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({widgetprivacybuild},); runOnlyForDeploymentPostprocessing = 0;')
widgetframeworks=add('widget:frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
widgetconfigs=[]
for name in ['Debug','Release']:
    settings={'CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':release['build_number'],'MARKETING_VERSION':release['version_name'],'DEVELOPMENT_TEAM':team,'GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'RelayWidget/Info.plist','PRODUCT_BUNDLE_IDENTIFIER':'dev.bluetoothswitch.iosrelay.shortcuts','PRODUCT_NAME':'RelayWidget','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','TARGETED_DEVICE_FAMILY':'1','APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'}
    config=add('widget:'+name,'isa = XCBuildConfiguration; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'}; name = '+name+';'); widgetconfigs.append(config)
widgetconfiglist=add('widget:configs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(widgetconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
widget=add('widget',f'isa = PBXNativeTarget; buildConfigurationList = {widgetconfiglist}; buildPhases = ({widgetsources},{widgetframeworks},{widgetresources},); buildRules = (); dependencies = (); name = RelayWidget; productName = RelayWidget; productReference = {widgetproduct}; productType = "com.apple.product-type.app-extension";')
widgetproxy=add('widget:proxy',f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {widget}; remoteInfo = RelayWidget;')
widgetdependency=add('widget:dependency',f'isa = PBXTargetDependency; target = {widget}; targetProxy = {widgetproxy};')
widgetembedbuild=add('widget:embedbuild',f'isa = PBXBuildFile; fileRef = {widgetproduct}; settings = {{ ATTRIBUTES = (CodeSignOnCopy,RemoveHeadersOnCopy,); }};')
widgetembed=add('widget:embed',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({widgetembedbuild},); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
objects=[obj.replace(f'children = ({app},);',f'children = ({app},{widgetproduct},);').replace(f'children = ({",".join(refs+[products])},);',f'children = ({",".join(refs+[widgetref,widgetprivacy,widgetplist,products])},);') for obj in objects]
target=add('target',f'isa = PBXNativeTarget; buildConfigurationList = {tconfigs}; buildPhases = ({phase},{fphase},{rphase},{widgetembed},); buildRules = (); dependencies = ({widgetdependency},); packageProductDependencies = ({",".join(package_products)},); name = AudioRelay; productName = "Audio Relay"; productReference = {app}; productType = "com.apple.product-type.application";')
proj=add('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2720; LastUpgradeCheck = 2720; }}; buildConfigurationList = {pconfigs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},{widget},); packageReferences = ({",".join(packages)},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n'+'\n'.join(objects)+f'\n\t}};\n\trootObject = {proj};\n}}\n')
schemes=project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Audio Relay.app" BlueprintName="AudioRelay" ReferencedContainer="container:AudioRelay.xcodeproj"/>'
(schemes/'AudioRelay.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated ios/AudioRelay.xcodeproj')
