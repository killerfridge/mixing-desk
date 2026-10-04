#import <Foundation/Foundation.h>
#import <CoreAudio/AudioServerPlugIn.h>
#import <CoreAudio/AudioHardware.h>
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
#include "../Sources/DeskAudio/DriverProtocol.h"
#include "../Sources/DeskAudio/DriverStatus.hpp"
extern "C" void* MixingDeskDriverFactory(CFAllocatorRef,CFUUIDRef);
static NSDictionary* storage;
static AudioServerPlugInDriverRef driver;
static int notifications=0;
static OSStatus changed(AudioServerPlugInHostRef,AudioObjectID,UInt32,const AudioObjectPropertyAddress*) {++notifications;return noErr;}
static OSStatus readStorage(AudioServerPlugInHostRef,CFStringRef,CFPropertyListRef* data) {*data=storage?(__bridge_retained CFPropertyListRef)storage:nullptr;return noErr;}
static OSStatus writeStorage(AudioServerPlugInHostRef,CFStringRef,CFPropertyListRef data) {storage=[(__bridge NSDictionary*)data copy];return noErr;}
static OSStatus deleteStorage(AudioServerPlugInHostRef,CFStringRef) {storage=nil;return noErr;}
static OSStatus requestChange(AudioServerPlugInHostRef,AudioObjectID device,UInt64 action,void* info) {return (*driver)->PerformDeviceConfigurationChange(driver,device,action,info);}
static AudioServerPlugInHostInterface host={changed,readStorage,writeStorage,deleteStorage,requestChange};
static AudioObjectPropertyAddress address(UInt32 selector,UInt32 scope=kAudioObjectPropertyScopeGlobal) {return {selector,scope,kAudioObjectPropertyElementMain};}
static OSStatus command(NSDictionary* d) {auto a=address(MD_DRIVER_CONFIG_SELECTOR);CFDictionaryRef cf=(__bridge CFDictionaryRef)d;return (*driver)->SetPropertyData(driver,kAudioObjectPlugInObject,0,&a,0,nullptr,sizeof(cf),&cf);}
static NSDictionary* configuration() {auto a=address(MD_DRIVER_CONFIG_SELECTOR);CFPropertyListRef value=nullptr;UInt32 size=sizeof(value);assert(!(*driver)->GetPropertyData(driver,kAudioObjectPlugInObject,0,&a,0,nullptr,size,&size,&value));return CFBridgingRelease(value);}
static std::vector<AudioObjectID> devices() {auto a=address(kAudioPlugInPropertyDeviceList);UInt32 size=0;assert(!(*driver)->GetPropertyDataSize(driver,kAudioObjectPlugInObject,0,&a,0,nullptr,&size));std::vector<AudioObjectID> result(size/sizeof(AudioObjectID));assert(!(*driver)->GetPropertyData(driver,kAudioObjectPlugInObject,0,&a,0,nullptr,size,&size,result.data()));return result;}
int main() { @autoreleasepool {
    using desk::DriverAvailability; using desk::driverAvailability;
    assert(driverAvailability(false,0,false,0,0)==DriverAvailability::missing);
    assert(driverAvailability(true,2,false,0,0)==DriverAvailability::restartRequired);
    assert(driverAvailability(false,0,true,2,1)==DriverAvailability::restartRequired);
    assert(driverAvailability(true,3,true,2,1)==DriverAvailability::restartRequired);
    assert(driverAvailability(true,1,true,1,1)==DriverAvailability::incompatible);
    assert(driverAvailability(true,2,true,2,2)==DriverAvailability::incompatible);
    assert(driverAvailability(true,2,true,0,0)==DriverAvailability::incompatible);
    assert(driverAvailability(true,2,true,2,1)==DriverAvailability::ready);
    driver=(AudioServerPlugInDriverRef)MixingDeskDriverFactory(nullptr,kAudioServerPlugInTypeUUID);assert(driver);
    assert(!(*driver)->Initialize(driver,&host));
    assert(!command(@{@"version":@1,@"operation":@"create",@"uid":@"test.call",@"name":@"Desk Call",@"channels":@2}));
    assert([configuration()[@"devices"] count]==1 && [storage[@"devices"] count]==1);
    assert([configuration()[@"driverBuild"] intValue]==MD_DRIVER_BUILD);
    auto list=devices();assert(list.size()==2);AudioObjectID publicDevice=list[0],bridge=list[1];
    auto hidden=address(kAudioDevicePropertyIsHidden);UInt32 value=0,size=4;
    assert(!(*driver)->GetPropertyData(driver,bridge,0,&hidden,0,nullptr,size,&size,&value));assert(value==1);
    auto clockPeriod=address(kAudioDevicePropertyZeroTimeStampPeriod);
    assert(!(*driver)->GetPropertyData(driver,bridge,0,&clockPeriod,0,nullptr,size,&size,&value));assert(value>=10923);
    Float64 sampleTime=0;UInt64 hostTime=0,seed=0;
    assert(!(*driver)->GetZeroTimeStamp(driver,bridge,21,&sampleTime,&hostTime,&seed));assert(uint64_t(sampleTime)%value==0 && seed!=0);
    auto stream=address(kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput);AudioObjectID input=0;size=4;
    assert(!(*driver)->GetPropertyData(driver,publicDevice,0,&stream,0,nullptr,size,&size,&input));assert(input==publicDevice+1);
    AudioServerPlugInClientInfo client{11,123,true,CFSTR("test.client")},client2{12,124,true,CFSTR("test.other")},mixer{21,125,true,CFSTR("local.mixingdesk.app")};
    assert(!(*driver)->AddDeviceClient(driver,publicDevice,&client));assert(!(*driver)->AddDeviceClient(driver,publicDevice,&client2));assert(!(*driver)->AddDeviceClient(driver,bridge,&mixer));
    assert(!(*driver)->StartIO(driver,publicDevice,11));assert(!(*driver)->StartIO(driver,publicDevice,12));assert(!(*driver)->StartIO(driver,bridge,21));
    assert(command(@{@"version":@1,@"operation":@"delete",@"uid":@"test.call"})!=noErr);
    assert([configuration()[@"devices"][0][@"clients"] unsignedIntValue]==2);
    constexpr int count=128;float outgoing[count*2],returning[count*2],received[count*2];for(int i=0;i<count;++i){outgoing[i*2]=.25;outgoing[i*2+1]=-.5;returning[i*2]=.1;returning[i*2+1]=.2;}
    AudioServerPlugInIOCycleInfo cycle{};cycle.mOutputTime.mSampleTime=1000;cycle.mInputTime.mSampleTime=1000+MD_DRIVER_LATENCY;
    assert(!(*driver)->DoIOOperation(driver,bridge,bridge+2,21,kAudioServerPlugInIOOperationWriteMix,count,&cycle,outgoing,nullptr));
    assert(!(*driver)->DoIOOperation(driver,publicDevice,publicDevice+2,11,kAudioServerPlugInIOOperationWriteMix,count,&cycle,returning,nullptr));
    for(int reader:{11,12}) {assert(!(*driver)->DoIOOperation(driver,publicDevice,publicDevice+1,reader,kAudioServerPlugInIOOperationReadInput,count,&cycle,received,nullptr));for(int i=0;i<count*2;++i)assert(received[i]==outgoing[i]);}
    assert(!(*driver)->DoIOOperation(driver,bridge,bridge+1,21,kAudioServerPlugInIOOperationReadInput,count,&cycle,received,nullptr));for(int i=0;i<count*2;++i)assert(received[i]==returning[i]);
    assert(!(*driver)->StopIO(driver,bridge,21));assert(!(*driver)->DoIOOperation(driver,publicDevice,publicDevice+1,11,kAudioServerPlugInIOOperationReadInput,count,&cycle,received,nullptr));for(float sample:received)assert(sample==0);
    // Restart at the old timestamp as well: a new writer generation must never replay old samples.
    assert(!(*driver)->StartIO(driver,bridge,21));assert(!(*driver)->DoIOOperation(driver,publicDevice,publicDevice+1,11,kAudioServerPlugInIOOperationReadInput,count,&cycle,received,nullptr));for(float sample:received)assert(sample==0);
    cycle.mInputTime.mSampleTime=10000;assert(!(*driver)->DoIOOperation(driver,publicDevice,publicDevice+1,11,kAudioServerPlugInIOOperationReadInput,count,&cycle,received,nullptr));for(float sample:received)assert(sample==0);
    assert(!command(@{@"version":@1,@"operation":@"rename",@"uid":@"test.call",@"name":@"Renamed Call"}));assert([configuration()[@"devices"][0][@"name"] isEqual:@"Renamed Call"]);
    assert(command(@{@"version":@2,@"operation":@"create",@"uid":@"bad",@"name":@"Bad",@"channels":@2})!=noErr);
    assert(command(@{@"version":@1,@"operation":@"create",@"uid":@"bad",@"name":@"Bad",@"channels":@65})!=noErr);
    assert(command(@{@"version":@1,@"operation":@"create",@"uid":@"bad",@"name":@"Bad",@"channels":@2.5})!=noErr);
    assert(command(@{@"version":@1,@"operation":@"create",@"uid":@"bad",@"name":@"Bad",@"channels":@[]})!=noErr);
    assert(command(@{@"version":@[],@"operation":@"create"})!=noErr);
    assert(command(@{@"version":@1,@"operation":@[]})!=noErr);
    assert(!(*driver)->StopIO(driver,bridge,21));assert(!(*driver)->StopIO(driver,publicDevice,11));assert(!(*driver)->StopIO(driver,publicDevice,12));
    // Registered idle clients are normal: HAL attaches device-list observers even
    // when they never start IO. They must not permanently prevent deletion.
    assert([configuration()[@"devices"][0][@"clients"] unsignedIntValue]==0);
    assert([configuration()[@"devices"][0][@"registeredClients"] unsignedIntValue]==2);
    assert(!command(@{@"version":@1,@"operation":@"delete",@"uid":@"test.call"}));assert([configuration()[@"devices"] count]==0);assert(notifications>0);
    for(int i=0;i<40;++i){assert(!command(@{@"version":@1,@"operation":@"create",@"uid":@"test.reused",@"name":@"Reused slot",@"channels":@1}));assert(devices()[0]!=publicDevice);assert(!command(@{@"version":@1,@"operation":@"delete",@"uid":@"test.reused"}));}
    std::cout<<"PASS: driver creation, persistence callback, hidden endpoint, channel enumeration, duplex isolation, multiple readers, active-client deletion refusal, stale/stopped silence, rename, validation and deletion.\n";
} }
