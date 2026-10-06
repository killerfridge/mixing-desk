#import "include/DeskAudio.h"
#import "Engine.hpp"
#import "PluginHost.hpp"
#import "DriverProtocol.h"
#import "DriverStatus.hpp"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AppKit/AppKit.h>
#import <mach/mach_time.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <unistd.h>

using namespace desk;
#ifdef MD_AUDIO_PROBE
// Test-only inspection; never compiled into the application.
extern void inspectProbeAudio(const float* const*, int, float* const*, int, int);
#endif
namespace {
AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) { return {sel,scope,kAudioObjectPropertyElementMain}; }
template<class T> T prop(AudioObjectID id, AudioObjectPropertySelector sel, T fallback={}, AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) {
    T value=fallback; UInt32 size=sizeof(T); auto a=addr(sel,scope);
    return AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&value)==noErr ? value : fallback;
}
template<class T> std::vector<T> list(AudioObjectID id, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) {
    auto a=addr(sel,scope); UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&size)!=noErr) return {};
    std::vector<T> result(size/sizeof(T));
    if(size && AudioObjectGetPropertyData(id,&a,0,nullptr,&size,result.data())!=noErr) return {};
    result.resize(size/sizeof(T)); return result;
}
NSString* strprop(AudioObjectID id, AudioObjectPropertySelector sel, NSString* fallback=@"") {
    CFStringRef s=prop<CFStringRef>(id,sel,nullptr); return s ? CFBridgingRelease(s) : fallback;
}
NSError* issue(NSString* text, OSStatus code=-1) { return [NSError errorWithDomain:@"MixingDesk.Audio" code:code userInfo:@{NSLocalizedDescriptionKey:text}]; }
bool fail(NSError** error, NSString* text, OSStatus code=-1) { if(error) *error=issue(text,code); return false; }
uint64_t identity(NSString* s) { uint64_t h=1469598103934665603ULL; const char* p=s.UTF8String; if(!p) return 1; while(*p) {h^=(uint8_t)*p++;h*=1099511628211ULL;} return h ? h : 1; }
int channels(AudioObjectID id, AudioObjectPropertyScope scope) {
    auto a=addr(kAudioDevicePropertyStreamConfiguration,scope); UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&size)||!size) return 0;
    std::vector<uint8_t> bytes(size);
    if(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,bytes.data())) return 0;
    auto* buffers=(AudioBufferList*)bytes.data(); int count=0;
    for(UInt32 b=0;b<buffers->mNumberBuffers;++b) count+=buffers->mBuffers[b].mNumberChannels;
    return count;
}
NSArray* channelNames(AudioObjectID id, int count, AudioObjectPropertyScope scope) {
    NSMutableArray* result=[NSMutableArray array];
    for(int i=0;i<count;++i) {
        auto a=addr(kAudioObjectPropertyElementName,scope); a.mElement=i+1;
        CFStringRef name=nullptr; UInt32 size=sizeof(name);
        NSString* label=nil;
        if(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&name)==noErr && name) label=CFBridgingRelease(name);
        [result addObject:label.length ? label : [NSString stringWithFormat:@"Channel %d",i+1]];
    } return result;
}
AudioObjectID deviceForUID(NSString* uid) {
    if(!uid.length) return kAudioObjectUnknown;
    auto a=addr(kAudioHardwarePropertyTranslateUIDToDevice); AudioObjectID id=0; UInt32 size=sizeof(id); CFStringRef cf=(__bridge CFStringRef)uid;
    AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(cf),&cf,&size,&id); return id;
}
NSString* sourceKey(NSDictionary* source) {
    if([source[@"kind"] isEqual:@"application"]) return [@"app:" stringByAppendingString:source[@"bundleID"] ?: @""];
    if([source[@"returnBundleID"] length]) return [@"app:" stringByAppendingString:source[@"returnBundleID"]];
    // Exclude all channels of a physical/virtual return, not only one stereo pair.
    return [@"device:" stringByAppendingString:source[@"deviceUID"] ?: @""];
}
AudioObjectID driverID() {
    for(auto id:list<AudioObjectID>(kAudioObjectSystemObject,kAudioHardwarePropertyPlugInList))
        if([strprop(id,kAudioPlugInPropertyBundleID) isEqual:@MD_DRIVER_BUNDLE_ID]) return id;
    return 0;
}
NSDictionary* driverConfiguration() {
    auto id=driverID(); if(!id) return nil;
    CFPropertyListRef value=nullptr; UInt32 size=sizeof(value); auto a=addr(MD_DRIVER_CONFIG_SELECTOR);
    if(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&value)) return nil;
    NSObject* result=CFBridgingRelease(value); return [result isKindOfClass:NSDictionary.class] ? (NSDictionary*)result : nil;
}
BOOL driverCommand(NSDictionary* command,NSError** error) {
    auto id=driverID(); if(!id) return fail(error,@"Install the optional Mixing Desk Audio component using the Mixing Desk installer, then restart your Mac. If it is already installed, restart to load it.");
    auto config=driverConfiguration();
    if([config[@"driverBuild"] intValue]<MD_DRIVER_BUILD || [config[@"version"] intValue]!=MD_DRIVER_PROTOCOL_VERSION)
        return fail(error,@"This virtual-audio driver is incompatible. Install the Mixing Desk Audio component from this app's release, then restart your Mac.");
    auto a=addr(MD_DRIVER_CONFIG_SELECTOR); CFDictionaryRef cf=(__bridge CFDictionaryRef)command;
    OSStatus status=AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(cf),&cf);
    if(status) return fail(error,[NSString stringWithFormat:@"Virtual-device change failed (%d). Devices in use cannot be removed; names and channel counts must be valid.",status],status);
    return YES;
}
struct Host {
    Engine engine;
    AudioObjectID aggregate=0; AudioDeviceIOProcID callback=nullptr;
    std::vector<AudioObjectID> taps;
    std::map<std::string,int> inputs,outputs,tapInputs;
    struct WatchedDevice { std::string uid; AudioObjectID id; int inputs,outputs; };
    std::vector<WatchedDevice> watched;
    int inputCount=0,outputCount=0;
    std::unique_ptr<float[]> input{new float[MaxChannels*MaxFrames]{}}, output{new float[MaxChannels*MaxFrames]{}};
    std::array<const float*,MaxChannels> inputPointers{};
    std::array<float*,MaxChannels> outputPointers{};
    std::atomic<uint64_t> cycles{0},underruns{0};
    std::atomic<float> load{0};
    std::atomic<bool> hardwareChanged{false};
    mach_timebase_info_data_t timebase{};
    uint64_t previousTime=0;
    int frames=128; double latencyMs=0;
    Host() { mach_timebase_info(&timebase); for(int i=0;i<MaxChannels;++i) {inputPointers[i]=input.get()+i*MaxFrames;outputPointers[i]=output.get()+i*MaxFrames;} }
};
OSStatus changed(AudioObjectID,UInt32,const AudioObjectPropertyAddress*,void* context) { ((Host*)context)->hardwareChanged=true; return noErr; }
OSStatus render(AudioObjectID,const AudioTimeStamp* now,const AudioBufferList* input,const AudioTimeStamp*,AudioBufferList* output,const AudioTimeStamp*,void* context) {
    auto& h=*(Host*)context; uint64_t start=mach_absolute_time();
    UInt32 n=0;
    if(output) for(UInt32 b=0;b<output->mNumberBuffers;++b) if(output->mBuffers[b].mNumberChannels) { n=output->mBuffers[b].mDataByteSize/(sizeof(float)*output->mBuffers[b].mNumberChannels); break; }
    if(!n && input) for(UInt32 b=0;b<input->mNumberBuffers;++b) if(input->mBuffers[b].mNumberChannels) {n=input->mBuffers[b].mDataByteSize/(sizeof(float)*input->mBuffers[b].mNumberChannels);break;}
    if(output) for(UInt32 b=0;b<output->mNumberBuffers;++b) if(output->mBuffers[b].mData) memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    if(!n || n>MaxFrames) {h.underruns++;return noErr;}
    for(int c=0;c<h.inputCount;++c) std::fill_n(h.input.get()+c*MaxFrames,n,0.f);
    int c=0;
    if(input) for(UInt32 b=0;b<input->mNumberBuffers;++b) {
        const auto& buffer=input->mBuffers[b]; const float* data=(const float*)buffer.mData;
        int ch=buffer.mNumberChannels; UInt32 available=ch ? buffer.mDataByteSize/(sizeof(float)*ch) : 0;
        for(int k=0;k<ch;++k,++c) if(c<MaxChannels && data) for(UInt32 f=0;f<std::min(n,available);++f) h.input[c*MaxFrames+f]=data[f*ch+k];
    }
    h.engine.render(h.inputPointers.data(),h.inputCount,h.outputPointers.data(),h.outputCount,(int)n);
#ifdef MD_AUDIO_PROBE
    inspectProbeAudio(h.inputPointers.data(),h.inputCount,h.outputPointers.data(),h.outputCount,(int)n);
#endif
    c=0;
    if(output) for(UInt32 b=0;b<output->mNumberBuffers;++b) {
        auto& buffer=output->mBuffers[b]; float* data=(float*)buffer.mData; int ch=buffer.mNumberChannels;
        UInt32 available=ch ? buffer.mDataByteSize/(sizeof(float)*ch) : 0;
        for(int k=0;k<ch;++k,++c) if(c<h.outputCount && data) for(UInt32 f=0;f<std::min(n,available);++f) data[f*ch+k]=h.output[c*MaxFrames+f];
    }
    double nanos=double(mach_absolute_time()-start)*h.timebase.numer/h.timebase.denom;
    h.load.store(nanos/(double(n)/48000*1e9));
    uint64_t tick=now ? now->mHostTime : start;
    if(h.previousTime && double(tick-h.previousTime)*h.timebase.numer/h.timebase.denom > double(n)/48000*1e9*1.8) h.underruns++;
    h.previousTime=tick; h.cycles++; return noErr;
}
NSDictionary* meter(Meter m, NSString* ownerID) { return @{ @"id":ownerID ?: @"", @"heldL":@(m.heldL),@"heldR":@(m.heldR),@"reductionDB":@(m.reductionDB), @"peakL":@(m.peakL),@"peakR":@(m.peakR),@"rmsL":@(m.rmsL),@"rmsR":@(m.rmsR),@"clip":@(m.clip)}; }
}

@implementation MDAudioController {
    std::unique_ptr<Host> _host;
    NSDictionary* _session;
    NSArray* _outputGroups;
    NSArray* _offline;
    NSString* _lastError;
    NSArray* _synchronization;
    MDPluginRack* _plugins;
}
- (instancetype)init { if((self=[super init])) { _host=std::make_unique<Host>();_plugins=[MDPluginRack new];_offline=@[];_lastError=@""; auto a=addr(kAudioHardwarePropertyDevices); AudioObjectAddPropertyListener(kAudioObjectSystemObject,&a,changed,_host.get()); } return self; }
+ (BOOL)runPluginScannerCommand {return desk::runVST3ScanCommand();}
+ (NSArray*)availablePlugins {return [MDPluginRack catalog];}
- (void)unloadPlugins {
    [self stop];Configuration empty;std::string error;
    _host->engine.publish(empty,error);_host->engine.activateStopped();
    _plugins=[MDPluginRack new];_session=nil;
}
- (NSDictionary*)pluginStates {return [_plugins states];}
- (void)reloadPlugin:(NSString*)insertID {[_plugins retry:insertID];}
- (MDPluginEditor*)pluginEditor:(NSString*)insertID {return [_plugins editor:insertID];}
+ (NSArray<NSNumber*>*)equalizerResponse:(NSDictionary<NSString*,NSNumber*>*)p {
    EQParameters settings{[p[@"lowFrequency"] doubleValue],[p[@"lowGain"] doubleValue],[p[@"midFrequency"] doubleValue],[p[@"midGain"] doubleValue],[p[@"midQ"] doubleValue],[p[@"highFrequency"] doubleValue],[p[@"highGain"] doubleValue],[p[@"outputGain"] doubleValue]};
    if(!settings.valid())return @[];
    auto coefficients=prepareEQ(settings);NSMutableArray* points=[NSMutableArray arrayWithCapacity:241];
    for(int i=0;i<=240;++i)[points addObject:@(eqResponseDB(coefficients,20*std::pow(1000.,double(i)/240)))];
    return points;
}
- (void)dealloc { [self stop]; auto a=addr(kAudioHardwarePropertyDevices); AudioObjectRemovePropertyListener(kAudioObjectSystemObject,&a,changed,_host.get()); }
- (NSArray*)devices {
    NSMutableArray* result=[NSMutableArray array];
    for(auto id:list<AudioObjectID>(kAudioObjectSystemObject,kAudioHardwarePropertyDevices)) {
        NSString* uid=strprop(id,kAudioDevicePropertyDeviceUID);
        if([uid hasPrefix:@"local.mixingdesk.aggregate."] || [uid hasSuffix:@".bridge"]) continue;
        int ins=channels(id,kAudioObjectPropertyScopeInput), outs=channels(id,kAudioObjectPropertyScopeOutput);
        auto rates=list<AudioValueRange>(id,kAudioDevicePropertyAvailableNominalSampleRates);
        bool rateOK=false; for(auto r:rates) if(r.mMinimum<=48000 && r.mMaximum>=48000) rateOK=true;
        auto range=prop<AudioValueRange>(id,kAudioDevicePropertyBufferFrameSizeRange);
        [result addObject:@{@"uid":uid,@"name":strprop(id,kAudioObjectPropertyName),@"inputChannels":@(ins),@"outputChannels":@(outs),@"inputs":channelNames(id,ins,kAudioObjectPropertyScopeInput),@"outputs":channelNames(id,outs,kAudioObjectPropertyScopeOutput),@"sampleRate":@(prop<Float64>(id,kAudioDevicePropertyNominalSampleRate)),@"supports48k":@(rateOK),@"minBuffer":@(range.mMinimum),@"maxBuffer":@(range.mMaximum),@"alive":@(prop<UInt32>(id,kAudioDevicePropertyDeviceIsAlive))}];
    } return result;
}
- (NSArray*)applications {
    NSMutableDictionary* grouped=[NSMutableDictionary dictionary];
    for(auto id:list<AudioObjectID>(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList)) {
        pid_t pid=prop<pid_t>(id,kAudioProcessPropertyPID); if(pid==getpid()) continue;
        NSRunningApplication* app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString* bundle=strprop(id,kAudioProcessPropertyBundleID,app.bundleIdentifier ?: @"");
        if(!bundle.length || [bundle isEqual:NSBundle.mainBundle.bundleIdentifier]) continue;
        // Group Chromium/Electron helper audio processes under their parent app.
        NSRange helper=[bundle rangeOfString:@".helper" options:NSCaseInsensitiveSearch];
        if(helper.location!=NSNotFound) bundle=[bundle substringToIndex:helper.location];
        NSMutableDictionary* item=grouped[bundle];
        if(!item) { item=[@{@"bundleID":bundle,@"name":app.localizedName ?: bundle,@"processIDs":[NSMutableArray array]} mutableCopy];grouped[bundle]=item; }
        [item[@"processIDs"] addObject:@(id)];
    }
    return [[grouped allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) { return [a[@"name"] compare:b[@"name"]]; }];
}
- (void)stop {
    if(!_host) return; auto& h=*_host;
    if(h.aggregate) {
        if(h.callback) {AudioDeviceStop(h.aggregate,h.callback);AudioDeviceDestroyIOProcID(h.aggregate,h.callback);h.callback=nullptr;}
        auto a=addr(kAudioObjectPropertyOwnedObjects); AudioObjectRemovePropertyListener(h.aggregate,&a,changed,&h);
        a=addr(kAudioDevicePropertyNominalSampleRate); AudioObjectRemovePropertyListener(h.aggregate,&a,changed,&h);
        AudioHardwareDestroyAggregateDevice(h.aggregate);h.aggregate=0;
    }
    for(const auto& device:h.watched) if(device.id) {
        for(auto selector:{kAudioDevicePropertyDeviceIsAlive,kAudioDevicePropertyNominalSampleRate,kAudioDevicePropertyStreams}) {
            auto a=addr(selector);AudioObjectRemovePropertyListener(device.id,&a,changed,&h);
        }
    }
    h.watched.clear();
    for(auto t:h.taps) AudioHardwareDestroyProcessTap(t);
    h.taps.clear(); h.inputs.clear();h.outputs.clear();h.tapInputs.clear();h.inputCount=h.outputCount=0;h.previousTime=0;h.load=0;
    h.engine.reset();[_plugins resetStopped];
}
- (BOOL)startSession:(NSDictionary*)session error:(NSError**)error {
    [self stop]; auto& h=*_host;
    _session=[session copy]; _lastError=@"";
    NSString* monitorUID=session[@"monitorDeviceUID"];
    AudioObjectID master=deviceForUID(monitorUID);
    if(!master || !channels(master,kAudioObjectPropertyScopeOutput)) return fail(error,@"Choose an available headphone/monitor output. Mixing Desk never falls back to the Mac speakers.");
    NSMutableArray* selected=[NSMutableArray arrayWithObject:monitorUID];
    NSMutableSet* requested=[NSMutableSet setWithObject:monitorUID];
    NSMutableArray* offline=[NSMutableArray array];
    NSDictionary* config=driverConfiguration(); NSMutableDictionary* bridges=[NSMutableDictionary dictionary];
    for(NSDictionary* v in config[@"devices"]) bridges[v[@"uid"]]=v[@"bridgeUID"];
    NSMutableSet* appBundles=[NSMutableSet set], *returnBundles=[NSMutableSet set];
    for(NSDictionary* strip in session[@"strips"]) {
        NSDictionary* source=strip[@"source"];
        if([source[@"kind"] isEqual:@"application"] && [source[@"bundleID"] length]) [appBundles addObject:source[@"bundleID"]];
        if([source[@"returnBundleID"] length]) [returnBundles addObject:source[@"returnBundleID"]];
        if([source[@"kind"] isEqual:@"device"] && [source[@"deviceUID"] length]) {
            NSString* publicUID=source[@"deviceUID"], *uid=bridges[publicUID] ?: publicUID;
            [requested addObject:uid];
            if(deviceForUID(uid)) {if(![selected containsObject:uid]) [selected addObject:uid];}
            else [offline addObject:strip[@"name"] ?: publicUID];
        }
    }
    for(NSString* bundle in returnBundles) if([appBundles containsObject:bundle]) return fail(error,@"An application is assigned both a process tap and a virtual return. Choose one capture path.");
    for(NSDictionary* route in session[@"routes"]) {
        NSString* publicUID=route[@"destinationUID"], *uid=bridges[publicUID] ?: publicUID;
        if(uid.length)[requested addObject:uid];
        if(uid.length && deviceForUID(uid)) {if(![selected containsObject:uid]) [selected addObject:uid];}
        else if(publicUID.length) [offline addObject:publicUID];
    }
    if([config[@"driverBuild"] intValue]<MD_DRIVER_BUILD || [config[@"version"] intValue]!=MD_DRIVER_PROTOCOL_VERSION) for(NSString* uid in selected) if([[bridges allValues] containsObject:uid])
        return fail(error,@"The virtual-audio driver is incompatible. Install the Mixing Desk Audio component from this app's release and restart your Mac before using virtual routes.");
    NSMutableArray* subs=[NSMutableArray array];
    int inputOffset=0,outputOffset=0;
    for(NSString* uid in selected) {
        AudioObjectID device=deviceForUID(uid);
        double rate=prop<Float64>(device,kAudioDevicePropertyNominalSampleRate);
        if(rate!=48000) {
            auto a=addr(kAudioDevicePropertyNominalSampleRate); double desired=48000;
            OSStatus code=AudioObjectSetPropertyData(device,&a,0,nullptr,sizeof(desired),&desired);
            if(code) return fail(error,[NSString stringWithFormat:@"%@ cannot use 48 kHz (%d).",strprop(device,kAudioObjectPropertyName),code],code);
        }
        h.inputs[uid.UTF8String]=inputOffset;h.outputs[uid.UTF8String]=outputOffset;
        for(NSString* publicUID in bridges) if([bridges[publicUID] isEqual:uid]) {h.inputs[publicUID.UTF8String]=inputOffset;h.outputs[publicUID.UTF8String]=outputOffset;}
        inputOffset+=channels(device,kAudioObjectPropertyScopeInput);outputOffset+=channels(device,kAudioObjectPropertyScopeOutput);
        // HAL's composition schema requires CFNumber, not CFBoolean (@YES).
        [subs addObject:@{@kAudioSubDeviceUIDKey:uid,@kAudioSubDeviceDriftCompensationKey:@([uid isEqual:monitorUID] ? 0 : 1)}];
    }
    NSMutableArray* tapList=[NSMutableArray array]; NSArray* apps=[self applications];
    for(NSString* bundle in [[appBundles allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary* app=nil; for(NSDictionary* candidate in apps) if([candidate[@"bundleID"] isEqual:bundle]) {app=candidate;break;}
        if(!app) {[offline addObject:bundle];continue;}
        CATapDescription* description=[[CATapDescription alloc] initStereoMixdownOfProcesses:app[@"processIDs"]];
        description.name=[@"Mixing Desk: " stringByAppendingString:bundle];[description setPrivate:YES];description.muteBehavior=CATapMutedWhenTapped;
        AudioObjectID tap=0; OSStatus code=AudioHardwareCreateProcessTap(description,&tap);
        if(code) {[self stop];return fail(error,[NSString stringWithFormat:@"Cannot capture %@ (%d). Enable system audio recording for Mixing Desk in System Settings → Privacy & Security.",bundle,code],code);}
        h.taps.push_back(tap);
        h.tapInputs[bundle.UTF8String]=inputOffset;
        auto format=prop<AudioStreamBasicDescription>(tap,kAudioTapPropertyFormat);
        inputOffset+=format.mChannelsPerFrame;
        [tapList addObject:@{@kAudioSubTapUIDKey:strprop(tap,kAudioTapPropertyUID),@kAudioSubTapDriftCompensationKey:@1}];
    }
    if(inputOffset>MaxChannels || outputOffset>MaxChannels) {[self stop];return fail(error,@"Selected devices exceed the 512-channel engine capacity.");}
    h.inputCount=inputOffset;h.outputCount=outputOffset;
    // Always clock from hardware, including when every captured application is idle.
    // TapAutoStart=YES waits for tap audio and stalls hardware-only/idle sessions.
    // A physical AudioDevice UID belongs in MainSubDevice, not ClockDevice
    // (which is reserved for a separate AudioClockDevice).
    NSMutableDictionary* aggregate=[@{@kAudioAggregateDeviceNameKey:@"Mixing Desk Engine",@kAudioAggregateDeviceUIDKey:[@"local.mixingdesk.aggregate." stringByAppendingString:NSUUID.UUID.UUIDString],@kAudioAggregateDeviceSubDeviceListKey:subs,@kAudioAggregateDeviceMainSubDeviceKey:monitorUID,@kAudioAggregateDeviceIsPrivateKey:@1,@kAudioAggregateDeviceIsStackedKey:@0} mutableCopy];
    if(tapList.count){aggregate[@kAudioAggregateDeviceTapListKey]=tapList;aggregate[@kAudioAggregateDeviceTapAutoStartKey]=@0;}
    OSStatus code=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate,&h.aggregate);
    if(code) {[self stop];return fail(error,[NSString stringWithFormat:@"Could not create the synchronized audio device (%d).",code],code);}
    auto rateAddress=addr(kAudioDevicePropertyNominalSampleRate);Float64 aggregateRate=48000;
    code=AudioObjectSetPropertyData(h.aggregate,&rateAddress,0,nullptr,sizeof(aggregateRate),&aggregateRate);
    if(code) {[self stop];return fail(error,@"The aggregate could not be configured for 48 kHz.",code);}
    UInt32 buffer=[session[@"bufferFrames"] unsignedIntValue] ?: 128;
    auto a=addr(kAudioDevicePropertyBufferFrameSize); code=AudioObjectSetPropertyData(h.aggregate,&a,0,nullptr,sizeof(buffer),&buffer);
    if(code) {[self stop];return fail(error,@"The selected devices do not support this buffer size. Try 128 or 256 frames.",code);}
    h.frames=prop<UInt32>(h.aggregate,kAudioDevicePropertyBufferFrameSize,buffer);
    NSMutableArray* synchronization=[NSMutableArray array];
    NSMutableSet* synchronizedUIDs=[NSMutableSet set];
    // HAL silently ignores CFBoolean drift flags in the creation dictionary.
    // The dictionary above uses CFNumber; also explicitly verify every member.
    // ActiveSubDeviceList contains underlying devices; the settable subdevice
    // objects are owned by the aggregate.
    for(auto sub:list<AudioObjectID>(h.aggregate,kAudioObjectPropertyOwnedObjects)) {
        if(prop<AudioClassID>(sub,kAudioObjectPropertyClass)!=kAudioSubDeviceClassID)continue;
        NSString* uid=strprop(sub,kAudioDevicePropertyDeviceUID);
        UInt32 enabled=[uid isEqual:monitorUID] ? 0 : 1;
        auto drift=addr(kAudioSubDevicePropertyDriftCompensation);
        code=AudioObjectSetPropertyData(sub,&drift,0,nullptr,sizeof(enabled),&enabled);
        UInt32 actual=prop<UInt32>(sub,kAudioSubDevicePropertyDriftCompensation,UINT32_MAX);
        if(code || actual!=enabled) {NSString* message=[NSString stringWithFormat:@"Could not verify clock synchronization for %@ (%d).",strprop(sub,kAudioObjectPropertyName),code];[self stop];return fail(error,message,code ?: -1);}
        if(enabled) {
            auto quality=addr(kAudioSubDevicePropertyDriftCompensationQuality);UInt32 high=kAudioAggregateDriftCompensationHighQuality;
            code=AudioObjectSetPropertyData(sub,&quality,0,nullptr,sizeof(high),&high);
            if(code) {[self stop];return fail(error,@"Could not configure drift-correction quality.",code);}
        }
        [synchronization addObject:@{@"uid":uid,@"name":strprop(sub,kAudioObjectPropertyName),@"driftCorrection":@(actual),@"sampleRate":@(prop<Float64>(sub,kAudioDevicePropertyNominalSampleRate))}];
        [synchronizedUIDs addObject:uid];
    }
    if(![synchronizedUIDs isEqualToSet:[NSSet setWithArray:selected]]) {[self stop];return fail(error,@"The aggregate's clock members are not ready. Stop and start audio again.");}
    _synchronization=[synchronization copy];
    if(![strprop(h.aggregate,kAudioAggregateDevicePropertyMainSubDevice) isEqual:monitorUID]) {[self stop];return fail(error,@"The headphone device was not selected as the aggregate clock source.");}
    if(h.frames>MaxFrames) {[self stop];return fail(error,@"Hardware buffer exceeds engine capacity.");}
    if(channels(h.aggregate,kAudioObjectPropertyScopeInput)!=inputOffset || channels(h.aggregate,kAudioObjectPropertyScopeOutput)!=outputOffset) {
        NSString* message=[NSString stringWithFormat:@"Aggregate channels are not ready (expected %d in / %d out, got %d / %d). Refresh devices and start again.",inputOffset,outputOffset,channels(h.aggregate,kAudioObjectPropertyScopeInput),channels(h.aggregate,kAudioObjectPropertyScopeOutput)];
        [self stop];return fail(error,message);
    }
    // HAL virtual streams must deliver native Float32 PCM to our IOProc.
    for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}) for(auto stream:list<AudioStreamID>(h.aggregate,kAudioDevicePropertyStreams,scope)) {
        auto format=prop<AudioStreamBasicDescription>(stream,kAudioStreamPropertyVirtualFormat);
        if(format.mFormatID!=kAudioFormatLinearPCM || !(format.mFormatFlags&kAudioFormatFlagIsFloat) || format.mBitsPerChannel!=32) {[self stop];return fail(error,@"A device exposes an unsupported virtual audio format; 32-bit float PCM is required.");}
    }
    UInt32 inputStreamLatency=0,outputStreamLatency=0;
    for(auto stream:list<AudioStreamID>(h.aggregate,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput))inputStreamLatency=std::max(inputStreamLatency,prop<UInt32>(stream,kAudioStreamPropertyLatency));
    for(auto stream:list<AudioStreamID>(h.aggregate,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput))outputStreamLatency=std::max(outputStreamLatency,prop<UInt32>(stream,kAudioStreamPropertyLatency));
    h.latencyMs=(2.0*h.frames+inputStreamLatency+outputStreamLatency+prop<UInt32>(h.aggregate,kAudioDevicePropertyLatency,0,kAudioObjectPropertyScopeInput)+prop<UInt32>(h.aggregate,kAudioDevicePropertyLatency,0,kAudioObjectPropertyScopeOutput)+prop<UInt32>(h.aggregate,kAudioDevicePropertySafetyOffset,0,kAudioObjectPropertyScopeInput)+prop<UInt32>(h.aggregate,kAudioDevicePropertySafetyOffset,0,kAudioObjectPropertyScopeOutput))/48.0;
    if(![self updateSession:session error:error]) {[self stop];return NO;}
    Host* callbackHost=&h;
    code=AudioDeviceCreateIOProcIDWithBlock(&h.callback,h.aggregate,nullptr,^(const AudioTimeStamp* now,const AudioBufferList* input,const AudioTimeStamp* inputTime,AudioBufferList* output,const AudioTimeStamp* outputTime){
        render(callbackHost->aggregate,now,input,inputTime,output,outputTime,callbackHost);
    });
    if(!code) code=AudioDeviceStart(h.aggregate,h.callback);
    if(code) {[self stop];return fail(error,[NSString stringWithFormat:@"Audio could not start (%d). Check microphone and system-audio permissions.",code],code);}
    for(auto sub:list<AudioObjectID>(h.aggregate,kAudioObjectPropertyOwnedObjects)) {
        if(prop<AudioClassID>(sub,kAudioObjectPropertyClass)!=kAudioSubDeviceClassID)continue;
        UInt32 expected=[strprop(sub,kAudioDevicePropertyDeviceUID) isEqual:monitorUID] ? 0 : 1;
        if(prop<UInt32>(sub,kAudioSubDevicePropertyDriftCompensation,UINT32_MAX)!=expected) {[self stop];return fail(error,@"Clock synchronization changed while audio was starting. Stop and start audio again.");}
    }
    a=addr(kAudioObjectPropertyOwnedObjects); AudioObjectAddPropertyListener(h.aggregate,&a,changed,&h);
    a=addr(kAudioDevicePropertyNominalSampleRate); AudioObjectAddPropertyListener(h.aggregate,&a,changed,&h);
    for(NSString* uid in requested) {
        auto id=deviceForUID(uid);
        h.watched.push_back({uid.UTF8String,id,channels(id,kAudioObjectPropertyScopeInput),channels(id,kAudioObjectPropertyScopeOutput)});
        if(id) for(auto selector:{kAudioDevicePropertyDeviceIsAlive,kAudioDevicePropertyNominalSampleRate,kAudioDevicePropertyStreams}) {
            auto watch=addr(selector);AudioObjectAddPropertyListener(id,&watch,changed,&h);
        }
    }
    h.hardwareChanged=false;h.cycles=0;h.underruns=0; _offline=[offline copy]; return YES;
}
- (BOOL)updateSession:(NSDictionary*)session error:(NSError**)error {
    auto& h=*_host; Configuration cfg;
    NSArray* strips=session[@"strips"], *buses=session[@"buses"], *routes=session[@"routes"];
    if(strips.count>MaxStrips || buses.count>MaxBuses || routes.count>MaxRoutes) return fail(error,@"Mixer capacity: 64 strips, 16 buses, 512 output routes.");
    [_plugins prepareSession:session retireAfter:h.engine.publishedGeneration()+1];
    cfg.outputProtectionEnabled=session[@"outputProtectionEnabled"] ? [session[@"outputProtectionEnabled"] boolValue] : true;
    cfg.stripCount=(int)strips.count;cfg.busCount=(int)buses.count;cfg.routeCount=(int)routes.count;
    auto index = [](NSArray* array,NSString* id) -> int { for(NSUInteger i=0;i<array.count;++i) if([array[i][@"id"] isEqual:id]) return (int)i;return -1; };
    auto inserts = [&](NSDictionary* dictionary,auto& owner) -> bool {
        NSArray* slots=dictionary[@"inserts"] ?: @[];
        if(![slots isKindOfClass:NSArray.class] || slots.count>MaxInserts)return fail(error,@"Up to four inserts are supported per channel or bus.");
        owner.insertCount=(int)slots.count;
        for(int j=0;j<owner.insertCount;++j) {
            NSDictionary* slot=slots[j];
            if(![slot isKindOfClass:NSDictionary.class] || ![slot[@"id"] isKindOfClass:NSString.class] || ![slot[@"id"] length])return fail(error,@"Unsupported or invalid insert.");
            auto& insert=owner.inserts[j];insert.identity=identity(slot[@"id"]);insert.bypassed=[slot[@"bypassed"] boolValue];
            if([@[@"au",@"vst3"] containsObject:slot[@"format"]]) {
                insert.external=[_plugins processor:slot[@"id"]];
                if(!insert.external)return fail(error,@"Plugin could not be prepared.");
                continue;
            }
            if(![slot[@"format"] isEqual:@"builtin"] || ![slot[@"identifier"] isEqual:@"local.mixingdesk.eq"])return fail(error,@"Unsupported insert format.");
            if(slot[@"state"] && slot[@"state"]!=NSNull.null) {
                if(![slot[@"state"] isKindOfClass:NSString.class] || [slot[@"state"] length]>8192)return fail(error,@"Invalid EQ state.");
                NSData* data=[[NSData alloc] initWithBase64EncodedString:slot[@"state"] options:0];
                NSDictionary* p=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if(![p isKindOfClass:NSDictionary.class])return fail(error,@"Invalid EQ state.");
                for(NSString* key in @[@"version",@"lowFrequency",@"lowGain",@"midFrequency",@"midGain",@"midQ",@"highFrequency",@"highGain",@"outputGain"])if(![p[key] isKindOfClass:NSNumber.class])return fail(error,@"Missing EQ setting.");
                if([p[@"version"] doubleValue]!=1)return fail(error,@"Unsupported EQ state version.");
                insert.parameters={[p[@"lowFrequency"] doubleValue],[p[@"lowGain"] doubleValue],[p[@"midFrequency"] doubleValue],[p[@"midGain"] doubleValue],[p[@"midQ"] doubleValue],[p[@"highFrequency"] doubleValue],[p[@"highGain"] doubleValue],[p[@"outputGain"] doubleValue]};
            }
        }return true;
    };
    for(int i=0;i<cfg.stripCount;++i) {
        NSDictionary* d=strips[i],*src=d[@"source"];auto& s=cfg.strips[i];
        if(!inserts(d,s))return NO;
        s.limiterEnabled=d[@"limiterEnabled"] ? [d[@"limiterEnabled"] boolValue] : true;
        s.identity=identity(d[@"id"]);s.sourceIdentity=identity(sourceKey(src));
        s.trim=dbGain([d[@"trimDB"] floatValue]);s.fader=dbGain([d[@"faderDB"] floatValue]);s.pan=[d[@"pan"] floatValue];s.polarity=[d[@"polarity"] boolValue];s.mute=[d[@"muted"] boolValue];s.solo=[d[@"solo"] boolValue];
        s.directGuitar=[session[@"monitoringMode"] isEqual:@"directGuitar"] && [d[@"role"] isEqual:@"guitar"];
        NSArray* ch=src[@"channels"];s.mono=ch.count<2;
        int offset=-1;int available=0;
        if([src[@"kind"] isEqual:@"application"]) {auto it=h.tapInputs.find([src[@"bundleID"] UTF8String] ?: ""); if(it!=h.tapInputs.end()){offset=it->second;available=2;}}
        else {NSString* uid=src[@"deviceUID"] ?: @"";auto it=h.inputs.find(uid.UTF8String);if(it!=h.inputs.end()){offset=it->second;available=channels(deviceForUID(uid),kAudioObjectPropertyScopeInput);}}
        if(offset>=0 && ch.count && [ch[0] intValue]<available && [ch[0] intValue]>=0) s.left=offset+[ch[0] intValue];
        if(offset>=0 && ch.count>1 && [ch[1] intValue]<available && [ch[1] intValue]>=0) s.right=offset+[ch[1] intValue];
        NSArray* sends=d[@"sends"];if(sends.count>MaxSends)return fail(error,@"Too many strip sends.");s.sendCount=(int)sends.count;
        for(int j=0;j<s.sendCount;++j) s.sends[j]={index(buses,sends[j][@"busID"]),dbGain([sends[j][@"gainDB"] floatValue]),[sends[j][@"preFader"] boolValue]};
    }
    for(int i=0;i<cfg.busCount;++i) {
        NSDictionary* d=buses[i];auto& b=cfg.buses[i];b.identity=identity(d[@"id"]);b.gain=dbGain([d[@"gainDB"] floatValue]);b.mute=[d[@"muted"] boolValue];b.monitor=[d[@"kind"] isEqual:@"monitor"];
        if(!inserts(d,b))return NO;
        int exclusion=index(strips,d[@"excludedStripID"]);if(exclusion>=0)b.excludedSource=cfg.strips[exclusion].sourceIdentity;
        NSArray* sends=d[@"sends"];if(sends.count>MaxSends)return fail(error,@"Too many bus sends.");b.sendCount=(int)sends.count;
        for(int j=0;j<b.sendCount;++j)b.sends[j]={index(buses,sends[j][@"busID"]),dbGain([sends[j][@"gainDB"] floatValue]),false};
    }
    for(int i=0;i<cfg.routeCount;++i) {
        NSDictionary* d=routes[i];auto& r=cfg.routes[i];r.identity=identity(d[@"id"]);r.fromBus=[d[@"sourceKind"] isEqual:@"bus"];r.pre=[d[@"preFader"] boolValue];r.source=index(r.fromBus?buses:strips,d[@"sourceID"]);r.gain=dbGain([d[@"gainDB"] floatValue]);
        NSString* uid=d[@"destinationUID"] ?: @"";auto it=h.outputs.find(uid.UTF8String);NSArray* ch=d[@"channels"];
        int available=channels(deviceForUID(uid),kAudioObjectPropertyScopeOutput);
        if(it!=h.outputs.end() && ch.count && [ch[0] intValue]>=0 && [ch[0] intValue]<available)r.left=it->second+[ch[0] intValue];
        if(it!=h.outputs.end() && ch.count>1 && [ch[1] intValue]>=0 && [ch[1] intValue]<available)r.right=it->second+[ch[1] intValue];
    }
    NSMutableDictionary* destinations=[NSMutableDictionary dictionary];
    for(const auto& entry:h.outputs) {
        NSString* uid=[NSString stringWithUTF8String:entry.first.c_str()];AudioObjectID device=deviceForUID(uid);
        NSString* name=strprop(device,kAudioObjectPropertyName,uid);
        int count=channels(device,kAudioObjectPropertyScopeOutput);
        for(int channel=0;channel<count && entry.second+channel<MaxChannels;++channel) {
            int offset=entry.second+channel;
            cfg.outputIdentities[offset]=identity([NSString stringWithFormat:@"%@:%d",uid,channel]);
            destinations[@(offset)]=@{@"uid":uid,@"channel":@(channel),@"name":[NSString stringWithFormat:@"%@ · Ch %d",name,channel+1]};
        }
    }
    std::string message;
    if(!cfg.validate(message))return fail(error,[NSString stringWithUTF8String:message.c_str()]);
    NSMutableArray* groups=[NSMutableArray array];
    for(int g=0;g<cfg.protectionGroupCount;++g) {
        const auto& group=cfg.protectionGroups[g];NSMutableArray* members=[NSMutableArray array];
        for(int c=group.firstChannel;c>=0;c=cfg.nextProtectionChannel[c])if(destinations[@(c)])[members addObject:destinations[@(c)]];
        [groups addObject:@{@"id":[NSString stringWithFormat:@"%llu",(unsigned long long)group.identity],@"identity":@(group.identity),@"destinations":members}];
    }
    if(!h.engine.publish(cfg,message))return fail(error,[NSString stringWithUTF8String:message.c_str()]);
    if(!h.callback)h.engine.activateStopped();
    [_plugins collectThrough:h.engine.completedGeneration()];
    _outputGroups=[groups copy];_session=[session copy];return YES;
}
- (NSDictionary*)status {
    [_plugins collectThrough:_host->engine.completedGeneration()];
    NSMutableArray* strips=[NSMutableArray array],*buses=[NSMutableArray array],*outputs=[NSMutableArray array];
    for(NSUInteger i=0;i<[_session[@"strips"] count];++i)[strips addObject:meter(_host->engine.stripMeterForOwner(identity(_session[@"strips"][i][@"id"])),_session[@"strips"][i][@"id"])];
    for(NSUInteger i=0;i<[_session[@"buses"] count];++i)[buses addObject:meter(_host->engine.busMeterForOwner(identity(_session[@"buses"][i][@"id"])),_session[@"buses"][i][@"id"])];
    for(NSDictionary* group in _outputGroups) {
        NSMutableDictionary* data=[meter(_host->engine.outputMeterForGroup([group[@"identity"] unsignedLongLongValue]),group[@"id"]) mutableCopy];
        data[@"destinations"]=group[@"destinations"];[outputs addObject:data];
    }
    bool reconfigure=false;
    if(_host->hardwareChanged.exchange(false) && _host->aggregate) {
        for(const auto& device:_host->watched) {
            auto current=deviceForUID([NSString stringWithUTF8String:device.uid.c_str()]);
            if(current!=device.id || (current && (!prop<UInt32>(current,kAudioDevicePropertyDeviceIsAlive) || prop<Float64>(current,kAudioDevicePropertyNominalSampleRate)!=48000 || channels(current,kAudioObjectPropertyScopeInput)!=device.inputs || channels(current,kAudioObjectPropertyScopeOutput)!=device.outputs))) {reconfigure=true;break;}
        }
    }
    return @{@"outputProtection":outputs,@"protectionLatencyFrames":@(ProtectionLatency),@"plugins":[_plugins status],@"running":@(_host->aggregate!=0 && _host->callback),@"bufferFrames":@(_host->frames),@"estimatedLatencyMs":@(_host->latencyMs),@"load":@(_host->load.load()),@"underruns":@(_host->underruns.load()),@"cycles":@(_host->cycles.load()),@"hardwareChanged":@(reconfigure),@"synchronization":_synchronization ?: @[],@"offline":_offline ?: @[],@"strips":strips,@"buses":buses};
}
- (void)resetMeter:(NSString*)ownerID isBus:(BOOL)isBus { _host->engine.resetMeter(identity(ownerID),isBus);if(!_host->callback)_host->engine.serviceMeterResetsStopped(); }
- (void)resetAllMeters { _host->engine.resetAllMeters();if(!_host->callback)_host->engine.serviceMeterResetsStopped(); }
- (NSArray*)virtualDevices {return driverConfiguration()[@"devices"] ?: @[];}
- (NSDictionary*)driverStatus {
    NSString* path=@"/Library/Audio/Plug-Ins/HAL/MixingDeskAudio.driver/Contents/Info.plist";
    bool installed=[[NSFileManager defaultManager] fileExistsAtPath:path];
    NSDictionary* disk=[NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    bool loaded=driverID()!=0;
    NSDictionary* config=driverConfiguration();
    int installedBuild=[disk[@"CFBundleVersion"] intValue], loadedBuild=[config[@"driverBuild"] intValue], protocol=[config[@"version"] intValue];
    NSString* state; NSString* message;
    switch(desk::driverAvailability(installed,installedBuild,loaded,loadedBuild,protocol)) {
        case desk::DriverAvailability::missing:
            state=@"missing"; message=@"Optional driver not installed. Run the Mixing Desk installer and select Mixing Desk Audio to send mixes to other apps as a microphone or recording input."; break;
        case desk::DriverAvailability::restartRequired:
            state=@"restartRequired"; message=installed ? @"The installed driver is not loaded yet. Restart your Mac. If this message remains, reinstall the Mixing Desk Audio component." : @"The driver has been removed but is still loaded. Restart your Mac to finish removing it."; break;
        case desk::DriverAvailability::incompatible:
            state=@"incompatible"; message=@"This driver version is incompatible or unreadable. Install the Mixing Desk Audio component from this app's release, then restart your Mac."; break;
        case desk::DriverAvailability::ready:
            state=@"ready"; message=@"Mixing Desk Audio is ready. Create a device, patch a bus to it, then select it as an input in your call, stream, or recording app."; break;
    }
    return @{@"state":state,@"message":message,@"installedBuild":@(installedBuild),@"loadedBuild":@(loadedBuild),@"protocolVersion":@(protocol)};
}
- (BOOL)createVirtualDevice:(NSString*)name channels:(NSInteger)count error:(NSError**)error { return driverCommand(@{@"version":@MD_DRIVER_PROTOCOL_VERSION,@"operation":@"create",@"uid":[@"local.mixingdesk.virtual." stringByAppendingString:NSUUID.UUID.UUIDString],@"name":name,@"channels":@(count)},error); }
- (BOOL)renameVirtualDevice:(NSString*)uid name:(NSString*)name error:(NSError**)error { return driverCommand(@{@"version":@MD_DRIVER_PROTOCOL_VERSION,@"operation":@"rename",@"uid":uid,@"name":name},error); }
- (BOOL)deleteVirtualDevice:(NSString*)uid error:(NSError**)error { return driverCommand(@{@"version":@MD_DRIVER_PROTOCOL_VERSION,@"operation":@"delete",@"uid":uid},error); }
@end
