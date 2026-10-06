#!/usr/bin/env python3
"""Deterministically regenerate the checked-in native Xcode project; no dependencies."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def oid(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def add(key, **value):
    identifier = oid(key)
    objects[identifier] = value
    return identifier
def ref(path, kind):
    return add("file:" + path, isa="PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="<group>")
def phase(key, files, kind="PBXSourcesBuildPhase"):
    builds = [add(f"build:{key}:{f}", isa="PBXBuildFile", fileRef=f) for f in files]
    return add("phase:"+key, isa=kind, buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")
def configs(key, settings):
    values = []
    for name in ("Debug", "Release"):
        config = dict(settings)
        config.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if name=="Debug" else "-O", GCC_OPTIMIZATION_LEVEL="0" if name=="Debug" else "2", ENABLE_TESTABILITY="YES" if name=="Debug" else "NO")
        values.append(add(f"config:{key}:{name}", isa="XCBuildConfiguration", name=name, buildSettings=config))
    return add("configs:"+key, isa="XCConfigurationList", buildConfigurations=values, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

all_files = []
def sources(paths):
    result=[]
    for path in paths:
        extension=Path(path).suffix
        f=ref(path,{".swift":"sourcecode.swift",".cpp":"sourcecode.cpp.cpp",".mm":"sourcecode.cpp.objcpp",".h":"sourcecode.c.h",".hpp":"sourcecode.cpp.h",".plist":"text.plist.xml"}.get(extension,"text"))
        if f not in all_files: all_files.append(f)
        result.append(f)
    return result

specs = {
    "DeskAudio": ("com.apple.product-type.library.static", "libDeskAudio.a", sources(["Sources/DeskAudio/Engine.cpp","Sources/DeskAudio/AudioHost.mm","Sources/DeskAudio/AudioUnitHost.mm","Sources/DeskAudio/PluginHost.mm","Sources/DeskAudio/VST3Host.mm","Sources/DeskAudio/VST3Identifiers.cpp","Sources/DeskAudio/VST3SDK/pluginterfaces/base/funknown.cpp"]), []),
    "DeskModels": ("com.apple.product-type.library.static", "libDeskModels.a", sources(sorted(str(p.relative_to(ROOT)) for p in (ROOT/"Sources/DeskModels").glob("*.swift"))), []),
    "MixingDesk": ("com.apple.product-type.application", "Mixing Desk.app", sources(sorted(str(p.relative_to(ROOT)) for p in (ROOT/"Sources/MixingDesk").glob("*.swift"))), ["DeskAudio","DeskModels"]),
    "MixingDeskAudio": ("com.apple.product-type.bundle", "MixingDeskAudio.driver", sources(["Driver/Driver.mm"]), []),
    "DeskModelsTests": ("com.apple.product-type.bundle.unit-test", "DeskModelsTests.xctest", sources(sorted(str(p.relative_to(ROOT)) for p in (ROOT/"Tests/DeskModelsTests").glob("*.swift"))), ["DeskModels"]),
}
sources(["Sources/DeskAudio/Engine.hpp","Sources/DeskAudio/AudioUnitHost.hpp","Sources/DeskAudio/PluginHost.hpp","Sources/DeskAudio/VST3Support.hpp","Sources/DeskAudio/Equalizer.hpp","Sources/DeskAudio/PeakProtection.hpp","Sources/DeskAudio/InsertProcessor.hpp","Sources/DeskAudio/include/DeskAudio.h","Sources/DeskAudio/include/module.modulemap","Sources/DeskAudio/DriverProtocol.h","Sources/DeskAudio/DriverStatus.hpp","Driver/TimestampRing.hpp","Resources/Info.plist","Driver/Info.plist","Tests/EngineTests.cpp","Tests/EQChecks.hpp","Tests/ProtectionChecks.hpp","Tests/HostedInsertChecks.hpp","Tests/AudioUnitTests.mm","Tests/DriverTests.mm"])
app_resources=sources(["Sources/DeskAudio/VST3SDK/pluginterfaces/LICENSE.txt", "LICENSE", "Resources/MixingDesk.icns"])
driver_resources=sources(["LICENSE"])
products={}
for name, (_, product, _, _) in specs.items():
    products[name]=add("product:"+name,isa="PBXFileReference",explicitFileType="archive.ar" if product.endswith(".a") else "wrapper.application" if product.endswith(".app") else "wrapper.cfbundle",includeInIndex="0",path=product,sourceTree="BUILT_PRODUCTS_DIR")
frameworks={}
for name in ["Foundation","CoreAudio","AudioToolbox","AudioUnit","CoreAudioKit","AppKit","AVFoundation","SwiftUI"]:
    frameworks[name]=add("framework:"+name,isa="PBXFileReference",lastKnownFileType="wrapper.framework",name=name+".framework",path="System/Library/Frameworks/"+name+".framework",sourceTree="SDKROOT")

for name,(product_type,product,files,deps) in specs.items():
    settings={"PRODUCT_NAME": "Mixing Desk" if name=="MixingDesk" else name,"PRODUCT_MODULE_NAME":name,"CODE_SIGN_STYLE":"Manual","CODE_SIGN_IDENTITY":"-","SWIFT_VERSION":"5.0","MACOSX_DEPLOYMENT_TARGET":"14.4","SDKROOT":"macosx","ARCHS":"arm64","CLANG_ENABLE_OBJC_ARC":"YES","CLANG_CXX_LANGUAGE_STANDARD":"c++20","HEADER_SEARCH_PATHS":["$(inherited)","$(SRCROOT)/Sources/DeskAudio/include","$(SRCROOT)/Sources/DeskAudio/VST3SDK"],"SWIFT_INCLUDE_PATHS":["$(inherited)","$(BUILT_PRODUCTS_DIR)"],"ENABLE_USER_SCRIPT_SANDBOXING":"YES"}
    if name=="MixingDesk":
        settings.update(PRODUCT_BUNDLE_IDENTIFIER="local.mixingdesk.app",INFOPLIST_FILE="Resources/Info.plist",EXECUTABLE_NAME="MixingDesk",LD_RUNPATH_SEARCH_PATHS=["$(inherited)","@executable_path/../Frameworks"],OTHER_LDFLAGS=["$(inherited)","-lc++","-ObjC"])
    elif name=="MixingDeskAudio":
        settings.update(PRODUCT_BUNDLE_IDENTIFIER="local.mixingdesk.driver",INFOPLIST_FILE="Driver/Info.plist",WRAPPER_EXTENSION="driver",MACH_O_TYPE="mh_bundle",SKIP_INSTALL="YES")
    elif name=="DeskModelsTests":
        settings.update(PRODUCT_BUNDLE_IDENTIFIER="local.mixingdesk.modeltests",GENERATE_INFOPLIST_FILE="YES",SKIP_INSTALL="YES")
    else:
        settings.update(SKIP_INSTALL="YES",DEFINES_MODULE="YES")
        if name=="DeskAudio":settings["MODULEMAP_FILE"]="Sources/DeskAudio/include/module.modulemap"
    links=[products[d] for d in deps]
    if name in ("MixingDesk","MixingDeskAudio"):links += list(frameworks.values()) if name=="MixingDesk" else [frameworks["Foundation"],frameworks["CoreAudio"]]
    dependencies=[]
    for dep in deps:
        proxy=add(f"proxy:{name}:{dep}",isa="PBXContainerItemProxy",containerPortal=oid("project"),proxyType="1",remoteGlobalIDString=oid("target:"+dep),remoteInfo=dep)
        dependencies.append(add(f"dependency:{name}:{dep}",isa="PBXTargetDependency",target=oid("target:"+dep),targetProxy=proxy))
    add("target:"+name,isa="PBXNativeTarget",buildConfigurationList=configs(name,settings),buildPhases=[phase(name,files),phase(name+":frameworks",links,"PBXFrameworksBuildPhase")]+([phase(name+":resources",app_resources if name=="MixingDesk" else driver_resources,"PBXResourcesBuildPhase")] if name in ("MixingDesk", "MixingDeskAudio") else []),buildRules=[],dependencies=dependencies,name=name,productName=name,productReference=products[name],productType=product_type)

product_group=add("products",isa="PBXGroup",children=list(products.values()),name="Products",sourceTree="<group>")
framework_group=add("frameworks",isa="PBXGroup",children=list(frameworks.values()),name="Frameworks",sourceTree="<group>")
root_group=add("root",isa="PBXGroup",children=all_files+[framework_group,product_group],sourceTree="<group>")
project=add("project",isa="PBXProject",attributes={"LastUpgradeCheck":"1600","BuildIndependentTargetsInParallel":"YES"},buildConfigurationList=configs("project",{"CLANG_ENABLE_MODULES":"YES","CLANG_WARN_DOCUMENTATION_COMMENTS":"YES","GCC_WARN_64_TO_32_BIT_CONVERSION":"YES","SWIFT_STRICT_CONCURRENCY":"targeted"}),compatibilityVersion="Xcode 14.0",developmentRegion="en",hasScannedForEncodings="0",knownRegions=["en","Base"],mainGroup=root_group,productRefGroup=product_group,projectDirPath="",projectRoot="",targets=[oid("target:"+name) for name in specs])

def serialize(value,level=0):
    indent="\t"*level
    if isinstance(value,dict):return "{\n"+"".join(indent+"\t"+json.dumps(k)+" = "+serialize(v,level+1)+";\n" for k,v in value.items())+indent+"}"
    if isinstance(value,list):return "(\n"+"".join(indent+"\t"+serialize(v,level+1)+",\n" for v in value)+indent+")"
    return json.dumps(value)
directory=ROOT/"MixingDesk.xcodeproj"
directory.mkdir(exist_ok=True)
(directory/"project.pbxproj").write_text("// !$*UTF8*$!\n"+serialize({"archiveVersion":"1","classes":{},"objectVersion":"56","objects":objects,"rootObject":project})+"\n")
scheme_dir=directory/"xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True,exist_ok=True)
def buildable(name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid("target:"+name)}" BuildableName="{specs[name][1]}" BlueprintName="{name}" ReferencedContainer="container:MixingDesk.xcodeproj"/>'
(scheme_dir/"MixingDesk.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable("MixingDesk")}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable("MixingDeskAudio")}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable("DeskModelsTests")}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("MixingDesk")}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("MixingDesk")}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated MixingDesk.xcodeproj")
