#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#include <iostream>
int main() { @autoreleasepool {
    [NSApplication sharedApplication];
    AudioDeviceID output=0;UInt32 size=sizeof(output);
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,nullptr,&size,&output))return 1;
    AudioDeviceIOProcID proc=nullptr;
    if(AudioDeviceCreateIOProcIDWithBlock(&proc,output,nullptr,^(const AudioTimeStamp*,const AudioBufferList*,const AudioTimeStamp*,AudioBufferList* buffers,const AudioTimeStamp*){for(UInt32 i=0;i<buffers->mNumberBuffers;++i)if(buffers->mBuffers[i].mData)memset(buffers->mBuffers[i].mData,0,buffers->mBuffers[i].mDataByteSize);}))return 2;
    if(AudioDeviceStart(output,proc))return 3;
    std::cout<<"Silent test source ready: "<<NSBundle.mainBundle.bundleIdentifier.UTF8String<<std::endl;
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:30];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    AudioDeviceStop(output,proc);AudioDeviceDestroyIOProcID(output,proc);return 0;
} }
