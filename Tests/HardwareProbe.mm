#import <Foundation/Foundation.h>
#import "../Sources/DeskAudio/include/DeskAudio.h"
#import <CoreAudio/CoreAudio.h>
#include <atomic>
#include <iostream>
// Read-only by default. --silent-io exercises an aggregate with every output zero.
// No microphone samples are printed, recorded, or sent to another application.
int main(int argc,char** argv) { @autoreleasepool {
    if([MDAudioController runPluginScannerCommand])return 0;
    MDAudioController* audio=[MDAudioController new];
    NSArray* devices=[audio devices];
    NSData* json=[NSJSONSerialization dataWithJSONObject:@{@"devices":devices,@"applications":[audio applications],@"virtualDevices":[audio virtualDevices]} options:NSJSONWritingPrettyPrinted error:nil];
    if(argc<2){std::cout.write((const char*)json.bytes,json.length);std::cout<<"\n";return 0;}
    bool direct=std::string(argv[1])=="--device-io",tap=std::string(argv[1])=="--tap-io",blackhole=std::string(argv[1])=="--blackhole-io";
    if(std::string(argv[1])!="--silent-io"&&!direct&&!tap&&!blackhole)return 2;
    NSString* qc=nil,*mic=nil;
    for(NSDictionary* device in devices){if([device[@"name"] isEqual:@"Quad Cortex"])qc=device[@"uid"];if([device[@"name"] containsString:@"VideoMic"])mic=device[@"uid"];}
    if(!qc||!mic){std::cerr<<"Quad Cortex and VideoMic are required for this check.\n";return 3;}
    if(direct){
        CFStringRef uid=(__bridge CFStringRef)qc;AudioDeviceID device=0;UInt32 size=sizeof(device);
        AudioObjectPropertyAddress a{kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(uid),&uid,&size,&device);
        std::atomic<uint64_t> count{0};auto* counter=&count;AudioDeviceIOProcID proc=nullptr;
        OSStatus status=AudioDeviceCreateIOProcIDWithBlock(&proc,device,nullptr,^(const AudioTimeStamp*,const AudioBufferList*,const AudioTimeStamp*,AudioBufferList* out,const AudioTimeStamp*){++*counter;for(UInt32 i=0;i<out->mNumberBuffers;++i)if(out->mBuffers[i].mData)memset(out->mBuffers[i].mData,0,out->mBuffers[i].mDataByteSize);});
        if(status)return 6;std::cerr<<"Starting direct Quad Cortex silent IO…\n";
        status=AudioDeviceStart(device,proc);if(status)return 7;
        NSDate* end=[NSDate dateWithTimeIntervalSinceNow:5];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        std::cout<<"Direct device callbacks: "<<count.load()<<std::endl;AudioDeviceStop(device,proc);AudioDeviceDestroyIOProcID(device,proc);return count.load()>0?0:8;
    }
    NSMutableArray* strips=[NSMutableArray arrayWithObject:@{@"id":@"probe-mic",@"name":@"Mic",@"source":@{@"kind":@"device",@"deviceUID":mic,@"channels":@[@0]},@"sends":@[],@"muted":@YES}];
    if(blackhole)[strips addObject:@{@"id":@"probe-blackhole",@"name":@"BlackHole",@"source":@{@"kind":@"device",@"deviceUID":@"BlackHole16ch_UID",@"channels":@[@14,@15]},@"sends":@[],@"muted":@YES}];
    if(tap){
        bool found=false;for(NSDictionary* app in [audio applications])if([app[@"bundleID"] isEqual:@"local.mixingdesk.testsource"])found=true;
        if(!found){std::cerr<<"Launch the controlled silent test source first.\n";return 9;}
        [strips addObject:@{@"id":@"probe-app",@"name":@"Test Application",@"source":@{@"kind":@"application",@"bundleID":@"local.mixingdesk.testsource",@"channels":@[@0,@1]},@"sends":@[],@"muted":@YES}];
    }
    NSDictionary* session=@{@"monitorDeviceUID":qc,@"bufferFrames":@128,@"monitoringMode":@"mixer",@"strips":strips,@"buses":@[],@"routes":@[]};
    NSError* error=nil;
    if(![audio startSession:session error:&error]){std::cerr<<error.localizedDescription.UTF8String<<"\n";return 4;}
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:5];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    NSDictionary* status=[audio status];
    bool synchronized=true,hasBlackHole=!blackhole;
    for(NSDictionary* member in status[@"synchronization"]) {
        bool clock=[member[@"uid"] isEqual:qc];
        if([member[@"driftCorrection"] unsignedIntValue]!=(clock?0:1))synchronized=false;
        if([member[@"uid"] isEqual:@"BlackHole16ch_UID"])hasBlackHole=true;
    }
    std::cout<<[status[@"synchronization"] description].UTF8String<<std::endl;
    std::cout<<"Silent aggregate I/O: "<<[status[@"cycles"] unsignedLongLongValue]<<" callbacks, "<<[status[@"bufferFrames"] intValue]<<" frames, "<<[status[@"underruns"] intValue]<<" suspected scheduling overruns.\n";
    std::cout.flush();[audio stop];
    return [status[@"cycles"] unsignedLongLongValue]>0 && synchronized && hasBlackHole?0:5;
} }
