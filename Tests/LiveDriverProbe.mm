// Exercises the installed HAL driver through Core Audio, using an isolated,
// temporary virtual device. --blackhole-soak also uses spare BlackHole channels;
// physical outputs stay silent and microphone samples are not retained or sent.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "../Sources/DeskAudio/DriverProtocol.h"
#import "../Sources/DeskAudio/include/DeskAudio.h"
#include <atomic>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <array>
#include <csignal>

struct WaveformAudit {
    float previous[2]{},beforePrevious[2]{};
    unsigned quietRun[2]{};
    std::atomic<uint64_t> samples{0},faults{0},missing{0};
    void sample(float value,int lane) {
        const double frequency=lane ? 997 : 331;
        float residual=value-2*std::cos(2*M_PI*frequency/48000)*previous[lane]+beforePrevious[lane];
        if(!std::isfinite(value) || std::abs(residual)>.002f)++faults;
        quietRun[lane]=std::abs(value)<1e-9f ? quietRun[lane]+1 : 0;
        if(quietRun[lane]>32)++missing;
        beforePrevious[lane]=previous[lane];previous[lane]=value;++samples;
    }
    void clearCounts(){samples=0;faults=0;missing=0;}
    void report(const char* name){std::cout<<name<<": "<<samples<<" samples, "<<faults<<" discontinuities, "<<missing<<" missing samples"<<std::endl;}
};
WaveformAudit aggregateInput,aggregateOutput,blackHoleNative;
std::atomic<bool> inspectBlackHole{false};
void inspectProbeAudio(const float* const* input,int inputs,float* const* output,int outputs,int frames) {
    if(!inspectBlackHole.load() || inputs<24 || outputs<42)return;
    // QC (8), BlackHole (16), microphone (1 input / 2 outputs), virtual (16).
    for(int f=0;f<frames;++f)for(int lane=0;lane<2;++lane) {
        aggregateInput.sample(input[22+lane][f],lane);
        aggregateOutput.sample(output[41-lane][f],lane);
    }
}

namespace {
volatile std::sig_atomic_t interrupted=0;
void interruptProbe(int){interrupted=1;}
template<class T> T readProperty(AudioObjectID id,UInt32 selector,T fallback={}) {
    AudioObjectPropertyAddress a{selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    T value=fallback;UInt32 size=sizeof(value);
    return AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&value) ? fallback : value;
}
std::vector<AudioObjectID> objects(AudioObjectID id,UInt32 selector) {
    AudioObjectPropertyAddress a{selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&size))return {};
    std::vector<AudioObjectID> result(size/sizeof(AudioObjectID));
    if(size && AudioObjectGetPropertyData(id,&a,0,nullptr,&size,result.data()))return {};
    return result;
}
void reportLiveClocks() {
    for(auto aggregate:objects(kAudioObjectSystemObject,kAudioHardwarePropertyDevices)) {
        CFStringRef uid=readProperty<CFStringRef>(aggregate,kAudioDevicePropertyDeviceUID);
        NSString* string=uid?CFBridgingRelease(uid):@"";
        if(![string hasPrefix:@"local.mixingdesk.aggregate."])continue;
        for(auto sub:objects(aggregate,kAudioObjectPropertyOwnedObjects)) {
            if(readProperty<UInt32>(sub,kAudioObjectPropertyClass)!=kAudioSubDeviceClassID)continue;
            CFStringRef n=readProperty<CFStringRef>(sub,kAudioObjectPropertyName);NSString* name=n?CFBridgingRelease(n):@"";
            std::cout<<"Live clock "<<name.UTF8String<<": drift="<<readProperty<UInt32>(sub,kAudioSubDevicePropertyDriftCompensation,999)<<std::endl;
        }
    }
}
AudioObjectPropertyAddress address(UInt32 selector) {
    return {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}
void check(OSStatus status, const char* operation) {
    if (status) throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(status));
}
void runFor(double seconds) {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0) {
        if(interrupted)throw std::runtime_error("Diagnostic interrupted");
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}
AudioObjectID plugin() {
    auto a = address(kAudioHardwarePropertyPlugInList); UInt32 size = 0;
    check(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,nullptr,&size), "Plugin list size");
    std::vector<AudioObjectID> ids(size/sizeof(AudioObjectID));
    check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,nullptr,&size,ids.data()), "Plugin list");
    for (auto objectID : ids) {
        a = address(kAudioPlugInPropertyBundleID); CFStringRef bundle = nullptr; size = sizeof(bundle);
        if (!AudioObjectGetPropertyData(objectID,&a,0,nullptr,&size,&bundle) && bundle) {
            bool match = CFEqual(bundle,CFSTR(MD_DRIVER_BUNDLE_ID)); CFRelease(bundle);
            if (match) return objectID;
        }
    }
    throw std::runtime_error("Mixing Desk driver is not loaded");
}
NSDictionary* configuration(AudioObjectID driver) {
    auto a = address(MD_DRIVER_CONFIG_SELECTOR); CFPropertyListRef value = nullptr; UInt32 size = sizeof(value);
    check(AudioObjectGetPropertyData(driver,&a,0,nullptr,&size,&value), "Driver configuration");
    return CFBridgingRelease(value);
}
OSStatus command(AudioObjectID driver, NSDictionary* command) {
    auto a = address(MD_DRIVER_CONFIG_SELECTOR); CFDictionaryRef value = (__bridge CFDictionaryRef)command;
    return AudioObjectSetPropertyData(driver,&a,0,nullptr,sizeof(value),&value);
}
AudioObjectID device(NSString* uid) {
    auto a = address(kAudioHardwarePropertyTranslateUIDToDevice);
    CFStringRef value = (__bridge CFStringRef)uid; AudioObjectID result = 0; UInt32 size = sizeof(result);
    AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(value),&value,&size,&result);
    return result;
}
constexpr int channelCount = 16;
struct Client {
    AudioDeviceID deviceID = 0;
    AudioDeviceIOProcID proc = nullptr;
    float writeScale = 0, readScale = 0;
    bool reverseChannels = false;
    bool toneReader = false, toneWriter = false;
    std::array<float,channelCount> previous{},beforePrevious{};
    std::array<unsigned,channelCount> quietRun{};
    std::atomic<uint64_t> toneSamples{0},toneFaults{0},toneSilence{0};
    std::atomic<bool> measure{false};
    std::atomic<uint64_t> callbacks{0}, good{0}, silent{0}, bad{0};
    bool started = false;
    static OSStatus render(AudioObjectID,const AudioTimeStamp*,const AudioBufferList* input,
                           const AudioTimeStamp*,AudioBufferList* output,const AudioTimeStamp* outputTime,void* context) {
        auto& self = *static_cast<Client*>(context); ++self.callbacks;
        if (input && self.measure.load()) {
            uint64_t good = 0, silent = 0, bad = 0; int channel = 0;
            for (UInt32 b=0;b<input->mNumberBuffers;++b) {
                const auto& buffer = input->mBuffers[b]; const auto* data = static_cast<const float*>(buffer.mData);
                const auto channels = buffer.mNumberChannels;
                const auto frames = channels ? buffer.mDataByteSize/(channels*sizeof(float)) : 0;
                if (data) for (UInt32 f=0;f<frames;++f) for (UInt32 c=0;c<channels;++c) {
                    if(self.toneWriter) {
                        if(channel+c==14 || channel+c==15)blackHoleNative.sample(data[f*channels+c],channel+c-14);
                        continue;
                    }
                    if(self.toneReader && channel+c<channelCount) {
                        int lane=channel+c;float sample=data[f*channels+c];
                        double frequency=(channelCount-1-lane)%2 ? 997 : 331;
                        float residual=sample-2*std::cos(2*M_PI*frequency/48000)*self.previous[lane]+self.beforePrevious[lane];
                        if(!std::isfinite(sample) || std::abs(residual)>.002f)++self.toneFaults;
                        self.quietRun[lane]=std::abs(sample)<1e-9f ? self.quietRun[lane]+1 : 0;
                        if(self.quietRun[lane]>32)++self.toneSilence;
                        self.beforePrevious[lane]=self.previous[lane];self.previous[lane]=sample;++self.toneSamples;
                        continue;
                    }
                    float sample=data[f*channels+c], expected=self.readScale*(self.reverseChannels ? channelCount-channel-c : channel+c+1);
                    if (std::abs(sample-expected)<0.00001f) ++good;
                    else if (std::abs(sample)<0.000001f) ++silent;
                    else ++bad;
                }
                channel += channels;
            }
            self.good += good; self.silent += silent; self.bad += bad;
        }
        if (output) {
            int channel = 0;
            for (UInt32 b=0;b<output->mNumberBuffers;++b) {
                auto& buffer=output->mBuffers[b]; auto* data=static_cast<float*>(buffer.mData);
                const auto channels=buffer.mNumberChannels;
                const auto frames=channels ? buffer.mDataByteSize/(channels*sizeof(float)) : 0;
                if (data) for (UInt32 f=0;f<frames;++f) for (UInt32 c=0;c<channels;++c) {
                    if(self.toneWriter) {
                        int lane=channel+c;
                        // Only BlackHole 15/16 carry the fixture. Existing user
                        // playback on channels 1/2 is not replaced or captured.
                        data[f*channels+c]=(lane==14 || lane==15) ? .02f*std::sin(2*M_PI*(lane==14?331:997)*(outputTime->mSampleTime+f)/48000) : 0;
                    } else data[f*channels+c]=self.writeScale*(channel+c+1);
                }
                channel += channels;
            }
        }
        return noErr;
    }
    void open(AudioObjectID id, float write, float read) {
        deviceID=id; writeScale=write; readScale=read;
        check(AudioDeviceCreateIOProcID(id,render,this,&proc),"Create IOProc");
    }
    void start() { check(AudioDeviceStart(deviceID,proc),"Start IO"); started=true; }
    void stop() { if (started) { check(AudioDeviceStop(deviceID,proc),"Stop IO"); started=false; } }
    void close() { stop(); if (proc) { check(AudioDeviceDestroyIOProcID(deviceID,proc),"Destroy IOProc"); proc=nullptr; } }
    void report(const char* name) {
        std::cout << name << ": " << callbacks << " callbacks, " << good << " matching, "
                  << silent << " silent, " << bad << " incorrect samples" << std::endl;
    }
    bool valid() {return good>48000 && bad==0 && silent<good/100;}
};
void aggregateCheck(NSString* uid,int seconds=5,bool blackhole=false,bool equalizers=false) {
    if (![uid hasPrefix:@"local.mixingdesk.test."]) throw std::runtime_error("Aggregate test only accepts temporary validation devices");
    MDAudioController* audio=[MDAudioController new];NSString* qc=nil,*mic=nil;
    for(NSDictionary* entry in [audio devices]) {
        if([entry[@"name"] isEqual:@"Quad Cortex"])qc=entry[@"uid"];
        if([entry[@"name"] containsString:@"VideoMic"])mic=entry[@"uid"];
    }
    if(!qc || !mic)throw std::runtime_error("Quad Cortex and VideoMic are required");
    if(!device(uid))throw std::runtime_error("Temporary validation device is missing");
    if(blackhole && !device(@"BlackHole16ch_UID"))throw std::runtime_error("BlackHole 16ch is required");
    NSMutableArray* strips=[NSMutableArray array],*routes=[NSMutableArray array];
    NSArray* buses=@[@{@"id":@"monitor",@"kind":@"monitor"},@{@"id":@"call",@"kind":@"call"},@{@"id":@"stream",@"kind":@"mix"},@{@"id":@"aux",@"kind":@"mix"}];
    for(int i=0;i<channelCount;++i) {
        NSString* strip=[NSString stringWithFormat:@"signal-%d",i];
        [strips addObject:@{@"id":strip,@"name":strip,@"source":@{@"kind":@"device",@"deviceUID":blackhole?@"BlackHole16ch_UID":uid,@"channels":@[@(blackhole?14+i%2:i)]},@"sends":@[@{@"busID":@"monitor"},@{@"busID":@"call"},@{@"busID":@"stream"},@{@"busID":@"aux"}]}];
        [routes addObject:@{@"id":[@"route-" stringByAppendingString:strip],@"sourceKind":@"strip",@"sourceID":strip,@"destinationUID":uid,@"channels":@[@(channelCount-1-i)]}];
    }
    [strips addObject:@{@"id":@"silent-mic",@"name":@"Microphone",@"source":@{@"kind":@"device",@"deviceUID":mic,@"channels":@[@0]},@"muted":@YES,@"sends":@[]}];
    if(equalizers) {
        NSDictionary* state=@{@"version":@1,@"lowFrequency":@120,@"lowGain":@(20*std::log10(2.)),@"midFrequency":@1000,@"midGain":@(-6),@"midQ":@1,@"highFrequency":@8000,@"highGain":@3,@"outputGain":@0};
        NSString* data=[[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] base64EncodedStringWithOptions:0];
        for(int i=0;i<channelCount;++i) {
            NSMutableDictionary* strip=[strips[i] mutableCopy];
            strip[@"inserts"]=@[@{@"id":[NSString stringWithFormat:@"eq-%d",i],@"format":@"builtin",@"identifier":@"local.mixingdesk.eq",@"bypassed":@NO,@"state":data}];strips[i]=strip;
        }
        NSMutableArray* processedBuses=[NSMutableArray array];
        for(NSDictionary* original in buses) {
            NSMutableDictionary* bus=[original mutableCopy];
            bus[@"inserts"]=@[@{@"id":[@"eq-bus-" stringByAppendingString:bus[@"id"]],@"format":@"builtin",@"identifier":@"local.mixingdesk.eq",@"bypassed":@NO,@"state":data}];
            [processedBuses addObject:bus];
        }buses=processedBuses;
    }
    NSDictionary* session=@{@"monitorDeviceUID":qc,@"bufferFrames":@128,@"monitoringMode":@"mixer",@"strips":strips,@"buses":buses,@"routes":routes};
    Client client,writer;client.open(device(uid),blackhole?0:-.002f,equalizers?-.004f:-.002f);client.reverseChannels=true;client.toneReader=blackhole;
    try {
        client.start();NSError* error=nil;
        if(blackhole){writer.toneWriter=true;writer.open(device(@"BlackHole16ch_UID"),0,0);writer.start();}
        if(![audio startSession:session error:&error])throw std::runtime_error(error.localizedDescription.UTF8String);
        inspectBlackHole=blackhole;
        std::cout<<[[audio status][@"synchronization"] description].UTF8String<<std::endl;
        runFor(.5);client.measure=true;
        // Warm the waveform checker before counting discontinuities.
        if(blackhole){writer.measure=true;runFor(.1);client.toneFaults=0;client.toneSilence=0;client.toneSamples=0;aggregateInput.clearCounts();aggregateOutput.clearCounts();blackHoleNative.clearCounts();reportLiveClocks();}
        for(int elapsed=0;elapsed<seconds;) {
            int step=std::min(30,seconds-elapsed);runFor(step);elapsed+=step;
            if(equalizers)std::cout<<"EQ workload "<<elapsed<<"s: 16 channel EQs + four bus EQs; "<<[[audio status][@"underruns"] intValue]<<" scheduling overruns"<<std::endl;
            if(blackhole)std::cout<<"SOAK "<<elapsed<<"s: "<<client.toneSamples<<" samples, "<<client.toneFaults<<" discontinuities, "<<client.toneSilence<<" missing samples, "<<[[audio status][@"underruns"] intValue]<<" scheduling overruns"<<std::endl;
            if(blackhole){blackHoleNative.report("Native BlackHole");aggregateInput.report("Aggregate input");aggregateOutput.report("Aggregate output");}
            if(blackhole && (client.toneFaults || client.toneSilence || aggregateInput.faults || aggregateInput.missing)){reportLiveClocks();break;}
        }
        client.measure=false;runFor(.05);
        if(blackhole) {
            bool valid=client.toneSamples>uint64_t(seconds)*48000*channelCount*.98 && client.toneFaults==0 && client.toneSilence==0
                && aggregateInput.samples>uint64_t(seconds)*96000*.98 && aggregateInput.faults==0 && aggregateInput.missing==0
                && aggregateOutput.faults==0 && aggregateOutput.missing==0 && blackHoleNative.faults==0 && blackHoleNative.missing==0;
            [audio stop];writer.close();client.close();
            if(!valid)throw std::runtime_error("BlackHole waveform continuity soak failed");
            std::cout<<"PASS: sustained BlackHole waveform continuity with Quad Cortex clock; physical outputs silent."<<std::endl;return;
        }
        client.report("Aggregate recording input (reversed channel map)");
        NSDictionary* status=[audio status];
        std::cout<<"Engine: "<<[status[@"cycles"] unsignedLongLongValue]<<" callbacks, "<<[status[@"bufferFrames"] intValue]<<" frames, "<<[status[@"underruns"] intValue]<<" suspected scheduling overruns."<<std::endl;
        bool valid=client.valid();[audio stop];runFor(.5);
        auto good=client.good.load(),silent=client.silent.load(),bad=client.bad.load();
        client.measure=true;runFor(.5);client.measure=false;runFor(.05);
        bool stopped=client.good==good && client.bad==bad && client.silent>silent;
        client.close();
        if(!valid)throw std::runtime_error("Aggregate channel mapping or audio continuity failed");
        if(!stopped)throw std::runtime_error("Aggregate stop left nonsilent virtual input");
        std::cout<<"PASS: Quad Cortex clock + RODE + virtual companion, 16 synthetic source strips, four buses, isolated direct outputs, and silence after engine stop. Physical outputs stayed silent."<<std::endl;
    } catch(...) {[audio stop];writer.close();client.close();throw;}
}
}
int main(int argc,char** argv) { @autoreleasepool {
    if([MDAudioController runPluginScannerCommand])return 0;
    std::signal(SIGINT,interruptProbe);std::signal(SIGTERM,interruptProbe);
    AudioObjectID driver=0; NSString* uid=nil; bool created=false;
    Client publicClient, bridgeClient, secondClient;
    auto cleanup = [&] {
        interrupted=0; // Finish HAL cleanup even after the user interrupts a soak.
        bool success=true;
        for (auto* client : {&secondClient,&bridgeClient,&publicClient}) try { client->close(); } catch (const std::exception& error) { success=false; std::cerr << error.what() << std::endl; }
        if (created) {
            OSStatus status=-1;
            for (int retry=0;retry<50 && status;++retry) {
                status=command(driver,@{@"version":@1,@"operation":@"delete",@"uid":uid});
                if(status)runFor(.1);
            }
            if(status){success=false;std::cerr<<"Temporary device needs cleanup: "<<uid.UTF8String<<" ("<<status<<")"<<std::endl;}
            else {created=false;std::cout<<"Temporary device removed."<<std::endl;}
        }
        return success;
    };
    try {
        driver=plugin(); NSDictionary* config=configuration(driver);
        std::cout<<"Mixing Desk driver loaded (build "<<(config[@"driverBuild"] ? [config[@"driverBuild"] intValue] : 1)<<"). Configuration v"<<[config[@"version"] intValue]
                 <<", "<<[config[@"devices"] count]<<" virtual devices."<<std::endl;
        if (argc>1 && std::string(argv[1])=="--inspect") return 0;
        if (argc==3 && std::string(argv[1])=="--aggregate") {aggregateCheck([NSString stringWithUTF8String:argv[2]]);return 0;}
        if([config[@"driverBuild"] intValue]<2)throw std::runtime_error("Driver update required: install build 2 and reload Core Audio before running device lifecycle checks");
        if (argc>1 && std::string(argv[1])=="--cleanup-tests") {
            for(NSDictionary* entry in config[@"devices"]) if([entry[@"uid"] hasPrefix:@"local.mixingdesk.test."])
                check(command(driver,@{@"version":@1,@"operation":@"delete",@"uid":entry[@"uid"]}),"Remove temporary test device");
            std::cout<<"Temporary test devices removed."<<std::endl;return 0;
        }
        uid=[@"local.mixingdesk.test." stringByAppendingString:NSUUID.UUID.UUIDString];
        check(command(driver,@{@"version":@1,@"operation":@"create",@"uid":uid,@"name":@"Mixing Desk — Temporary Validation",@"channels":@(channelCount)}),"Create test device"); created=true;
        AudioObjectID pub=0, bridge=0;
        for(int retry=0;retry<100 && (!pub || !bridge);++retry) {
            pub=device(uid); bridge=device([uid stringByAppendingString:@".bridge"]); if(!pub || !bridge)runFor(.05);
        }
        if(!pub || !bridge) throw std::runtime_error("Public or hidden companion endpoint did not appear");
        std::cout<<"Created 16-channel device and hidden companion."<<std::endl;
        auto hidden=address(kAudioDevicePropertyIsHidden); UInt32 isHidden=0,size=sizeof(isHidden);
        check(AudioObjectGetPropertyData(bridge,&hidden,0,nullptr,&size,&isHidden),"Read hidden flag");
        if(!isHidden)throw std::runtime_error("Companion is not hidden");
        if(argc==3 && std::string(argv[1])=="--blackhole-soak") {
            int seconds=std::stoi(argv[2]);if(seconds<1 || seconds>7200)throw std::runtime_error("Duration must be between 1 and 7200 seconds");
            aggregateCheck(uid,seconds,true);return cleanup()?0:1;
        }
        if(argc>=2 && std::string(argv[1])=="--eq-test") {
            int seconds=argc==3?std::stoi(argv[2]):5;if(seconds<1||seconds>7200)throw std::runtime_error("Duration must be between 1 and 7200 seconds");
            aggregateCheck(uid,seconds,false,true);return cleanup()?0:1;
        }
        publicClient.open(pub,-.002f,.001f); bridgeClient.open(bridge,.001f,-.002f); secondClient.open(pub,0,.001f);
        publicClient.start(); bridgeClient.start(); secondClient.start();
        if(!command(driver,@{@"version":@1,@"operation":@"delete",@"uid":uid}))throw std::runtime_error("Driver allowed deletion of an active device");
        runFor(.5); publicClient.measure=true;bridgeClient.measure=true;secondClient.measure=true;
        runFor(2); publicClient.measure=false;bridgeClient.measure=false;secondClient.measure=false;
        publicClient.report("App input");bridgeClient.report("Mixer return");secondClient.report("Second app input");
        if(!publicClient.valid() || !bridgeClient.valid() || !secondClient.valid())throw std::runtime_error("Duplex or channel isolation check failed");
        bridgeClient.stop();runFor(.5);
        auto previousGood=publicClient.good.load(),previousSilent=publicClient.silent.load(),previousBad=publicClient.bad.load();
        publicClient.measure=true;runFor(.5);publicClient.measure=false;runFor(.05);
        if(publicClient.good!=previousGood || publicClient.bad!=previousBad || publicClient.silent<=previousSilent)throw std::runtime_error("Virtual input did not become silent after mixer stopped");
        std::cout<<"Silence after mixer stop verified."<<std::endl;
        check(command(driver,@{@"version":@1,@"operation":@"rename",@"uid":uid,@"name":@"Mixing Desk — Validated"}),"Rename test device");
        bool renamed=false;for(NSDictionary* entry in configuration(driver)[@"devices"])if([entry[@"uid"] isEqual:uid])renamed=[entry[@"name"] isEqual:@"Mixing Desk — Validated"];
        if(!renamed)throw std::runtime_error("Rename was not reflected in driver configuration");
        if(!cleanup()){std::cerr<<"FAIL: temporary device cleanup"<<std::endl;return 1;}
        std::cout<<"PASS: live HAL creation, hidden companion, 16-channel duplex isolation, multiple clients, in-use protection, stop silence, rename and deletion."<<std::endl;return 0;
    } catch(const std::exception& error) {std::cerr<<"FAIL: "<<error.what()<<std::endl;cleanup();return 1;}
} }
