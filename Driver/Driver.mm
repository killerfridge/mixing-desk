#import <Foundation/Foundation.h>
#import <CoreAudio/AudioServerPlugIn.h>
#import <CoreAudio/AudioHardwareBase.h>
#import <CoreAudio/AudioHardware.h>
#import <mach/mach_time.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <set>
#include <vector>
#include "TimestampRing.hpp"
#include "../Sources/DeskAudio/DriverProtocol.h"

namespace {
AudioServerPlugInHostRef host=nullptr;
std::mutex control;
std::atomic<ULONG> references{1};
uint64_t epoch=0;double ticksPerFrame=0;
struct Pair {
    NSString* uid;NSString* name;int channels;AudioObjectID base;
    std::atomic<bool> alive{false};
    std::atomic<UInt32> publicIO{0},bridgeIO{0},publicFrames{128},bridgeFrames{128};
    std::set<UInt32> publicClients,bridgeClients;
    std::unique_ptr<desk::TimestampRing> toApps,fromApps;
    Pair(NSString* u,NSString* n,int ch,AudioObjectID b):uid([u copy]),name([n copy]),channels(ch),base(b),toApps(std::make_unique<desk::TimestampRing>(ch)),fromApps(std::make_unique<desk::TimestampRing>(ch)){}
};
std::array<std::unique_ptr<Pair>,MD_DRIVER_MAX_DEVICES> owned;
std::array<std::atomic<Pair*>,MD_DRIVER_MAX_DEVICES> pairs{};
// Retain tiny object metadata for concurrent stale property lookups. Audio storage
// is released only after all clients and IO have stopped. Object IDs never repeat.
std::vector<std::unique_ptr<Pair>> retired;
AudioObjectID nextID=100;
int allocated=0;
struct Object {Pair* pair=nullptr;int slot=-1,offset=-1;bool bridge=false,stream=false,input=false;AudioObjectID device=0;};
Object object(AudioObjectID id) {
    if(id<100)return {};
    for(int slot=0;slot<MD_DRIVER_MAX_DEVICES;++slot){
        Pair* p=pairs[slot].load(std::memory_order_acquire);if(!p || !p->alive.load() || id<p->base || id>p->base+6)continue;
        int offset=int(id-p->base);if(offset==3)continue;
        return {p,slot,offset,offset>=4,offset%4!=0,offset%4==1,UInt32(p->base+(offset>=4?4:0))};
    }return {};
}
AudioObjectPropertyAddress address(UInt32 selector,UInt32 scope=kAudioObjectPropertyScopeGlobal) {return {selector,scope,kAudioObjectPropertyElementMain};}
void notify(AudioObjectID id,UInt32 selector) {auto a=address(selector);host->PropertiesChanged(host,id,1,&a);}
NSDictionary* entry(Pair& p) { return @{@"uid":p.uid,@"name":p.name,@"channels":@(p.channels),@"bridgeUID":[p.uid stringByAppendingString:@".bridge"],@"clients":@(p.publicIO.load()),@"registeredClients":@(p.publicClients.size()),@"running":@(p.publicIO.load()>0)}; }
NSDictionary* configuration() {NSMutableArray* devices=[NSMutableArray array];for(auto& ptr:owned)if(ptr && ptr->alive)[devices addObject:entry(*ptr)];return @{@"version":@MD_DRIVER_PROTOCOL_VERSION,@"driverBuild":@MD_DRIVER_BUILD,@"devices":devices};}
OSStatus persist() {return host->WriteToStorage(host,CFSTR(MD_DRIVER_STORAGE_KEY),(__bridge CFPropertyListRef)configuration());}
OSStatus add(NSDictionary* d,bool loading=false) {
    if(![d isKindOfClass:NSDictionary.class]||![d[@"channels"] isKindOfClass:NSNumber.class])return kAudioHardwareIllegalOperationError;
    NSString* uid=d[@"uid"],*name=d[@"name"];double requested=[d[@"channels"] doubleValue];
    if(!std::isfinite(requested)||requested<1||requested>64||requested!=std::floor(requested))return kAudioHardwareIllegalOperationError;
    NSInteger ch=(NSInteger)requested;
    if(![uid isKindOfClass:NSString.class]||!uid.length||![name isKindOfClass:NSString.class]||!name.length||name.length>128||ch<1||ch>64)return kAudioHardwareIllegalOperationError;
    for(auto& p:owned)if(p&&p->alive&&[p->uid isEqual:uid])return kAudioHardwareIllegalOperationError;
    int slot=0;while(slot<MD_DRIVER_MAX_DEVICES && owned[slot] && owned[slot]->alive)++slot;
    if(slot==MD_DRIVER_MAX_DEVICES || nextID>UINT32_MAX-16)return kAudioHardwareIllegalOperationError;
    if(owned[slot])retired.push_back(std::move(owned[slot]));
    owned[slot]=std::make_unique<Pair>(uid,name,(int)ch,nextID);nextID+=16;allocated=std::max(allocated,slot+1);
    owned[slot]->alive=true;pairs[slot].store(owned[slot].get(),std::memory_order_release);
    if(!loading){OSStatus code=persist();if(code){owned[slot]->alive=false;return code;}}
    return noErr;
}
AudioStreamBasicDescription format(int ch) {return {MD_DRIVER_RATE,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagsNativeEndian,UInt32(ch*4),1,UInt32(ch*4),UInt32(ch),32,0};}
template<class T> OSStatus copy(const T& value,UInt32 size,UInt32* used,void* out) {if(size<sizeof(T))return kAudioHardwareBadPropertySizeError;memcpy(out,&value,sizeof(T));*used=sizeof(T);return noErr;}
OSStatus copyList(const std::vector<AudioObjectID>& values,UInt32 size,UInt32* used,void* out) {UInt32 bytes=UInt32(values.size()*sizeof(AudioObjectID));if(size<bytes)return kAudioHardwareBadPropertySizeError;if(bytes)memcpy(out,values.data(),bytes);*used=bytes;return noErr;}
OSStatus string(NSString* value,UInt32 size,UInt32* used,void* out) {CFStringRef cf=(__bridge CFStringRef)value;if(size<sizeof(cf))return kAudioHardwareBadPropertySizeError;CFRetain(cf);return copy(cf,size,used,out);}

HRESULT query(void*,REFIID uuid,LPVOID* result);
ULONG retain(void*) {return ++references;}
ULONG release(void*) {return --references;}
OSStatus initialize(AudioServerPlugInDriverRef,AudioServerPlugInHostRef h) {
    std::lock_guard lock(control);host=h;epoch=mach_absolute_time();mach_timebase_info_data_t tb;mach_timebase_info(&tb);ticksPerFrame=(1e9*tb.denom/tb.numer)/MD_DRIVER_RATE;
    CFPropertyListRef saved=nullptr;host->CopyFromStorage(host,CFSTR(MD_DRIVER_STORAGE_KEY),&saved);
    if(saved){NSDictionary* d=CFBridgingRelease(saved);if([d isKindOfClass:NSDictionary.class]&&[d[@"version"] isKindOfClass:NSNumber.class]&&[d[@"version"] doubleValue]==MD_DRIVER_PROTOCOL_VERSION&&[d[@"devices"] isKindOfClass:NSArray.class])for(NSDictionary* e in d[@"devices"])add(e,true);}
    return noErr;
}
OSStatus create(AudioServerPlugInDriverRef,CFDictionaryRef,const AudioServerPlugInClientInfo*,AudioObjectID*) {return kAudioHardwareUnsupportedOperationError;}
OSStatus destroy(AudioServerPlugInDriverRef,AudioObjectID) {return kAudioHardwareUnsupportedOperationError;}
OSStatus addClient(AudioServerPlugInDriverRef,AudioObjectID id,const AudioServerPlugInClientInfo* info) {std::lock_guard lock(control);auto o=object(id);if(!o.pair)return kAudioHardwareBadObjectError;(o.bridge?o.pair->bridgeClients:o.pair->publicClients).insert(info->mClientID);return noErr;}
OSStatus removeClient(AudioServerPlugInDriverRef,AudioObjectID id,const AudioServerPlugInClientInfo* info) {std::lock_guard lock(control);auto o=object(id);if(!o.pair)return kAudioHardwareBadObjectError;(o.bridge?o.pair->bridgeClients:o.pair->publicClients).erase(info->mClientID);return noErr;}
OSStatus perform(AudioServerPlugInDriverRef,AudioObjectID id,UInt64 action,void*) {auto o=object(id);if(!o.pair)return kAudioHardwareBadObjectError;if(action>=32&&action<=4096){(o.bridge?o.pair->bridgeFrames:o.pair->publicFrames)=UInt32(action);return noErr;}return kAudioHardwareIllegalOperationError;}
OSStatus abortChange(AudioServerPlugInDriverRef,AudioObjectID,UInt64,void*) {return noErr;}
Boolean has(AudioServerPlugInDriverRef,AudioObjectID id,pid_t,const AudioObjectPropertyAddress* a) {
    if(!a)return false;bool plugin=id==kAudioObjectPlugInObject;auto o=object(id);if(!plugin&&!o.pair)return false;
    switch(a->mSelector) {
        case kAudioObjectPropertyBaseClass:case kAudioObjectPropertyClass:case kAudioObjectPropertyOwner:case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioObjectPropertyOwnedObjects:return true;
    }
    if(plugin)switch(a->mSelector){case kAudioPlugInPropertyBundleID:case kAudioPlugInPropertyDeviceList:case kAudioPlugInPropertyTranslateUIDToDevice:case kAudioPlugInPropertyResourceBundle:case kAudioObjectPropertyCustomPropertyInfoList:case MD_DRIVER_CONFIG_SELECTOR:return true;default:return false;}
    if(o.stream)switch(a->mSelector){case kAudioStreamPropertyIsActive:case kAudioStreamPropertyDirection:case kAudioStreamPropertyTerminalType:case kAudioStreamPropertyStartingChannel:case kAudioStreamPropertyLatency:case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:return true;default:return false;}
    switch(a->mSelector){
        case kAudioDevicePropertyDeviceUID:case kAudioDevicePropertyModelUID:case kAudioDevicePropertyTransportType:case kAudioDevicePropertyRelatedDevices:case kAudioDevicePropertyClockDomain:case kAudioDevicePropertyDeviceIsAlive:case kAudioDevicePropertyDeviceIsRunning:case kAudioDevicePropertyDeviceCanBeDefaultDevice:case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:case kAudioDevicePropertyLatency:case kAudioDevicePropertyStreams:case kAudioObjectPropertyControlList:case kAudioDevicePropertySafetyOffset:case kAudioDevicePropertyNominalSampleRate:case kAudioDevicePropertyAvailableNominalSampleRates:case kAudioDevicePropertyIsHidden:case kAudioDevicePropertyPreferredChannelsForStereo:case kAudioDevicePropertyZeroTimeStampPeriod:case kAudioDevicePropertyClockAlgorithm:case kAudioDevicePropertyBufferFrameSize:case kAudioDevicePropertyBufferFrameSizeRange:case kAudioDevicePropertyUsesVariableBufferFrameSizes:case kAudioDevicePropertyStreamConfiguration:case kAudioDevicePropertyPreferredChannelLayout:case kAudioObjectPropertyElementName:return true;
        default:return false;
    }
}
OSStatus settable(AudioServerPlugInDriverRef driver,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a,Boolean* result) {
    if(!has(driver,id,pid,a))return kAudioHardwareUnknownPropertyError;
    *result=a->mSelector==MD_DRIVER_CONFIG_SELECTOR||a->mSelector==kAudioDevicePropertyBufferFrameSize||a->mSelector==kAudioDevicePropertyNominalSampleRate||a->mSelector==kAudioStreamPropertyVirtualFormat||a->mSelector==kAudioStreamPropertyPhysicalFormat||a->mSelector==kAudioStreamPropertyIsActive;return noErr;
}
std::vector<AudioObjectID> objects(AudioObjectID id,UInt32 selector,UInt32 scope) {
    std::vector<AudioObjectID> result;
    if(id==kAudioObjectPlugInObject){for(int i=0;i<allocated;++i)if(owned[i]->alive){result.push_back(owned[i]->base);result.push_back(owned[i]->base+4);}}
    else {auto o=object(id);if(o.pair&&!o.stream){if(selector==kAudioDevicePropertyRelatedDevices){result={o.pair->base,o.pair->base+4};}else if(selector!=kAudioObjectPropertyControlList){if(scope!=kAudioObjectPropertyScopeOutput)result.push_back(o.device+1);if(scope!=kAudioObjectPropertyScopeInput)result.push_back(o.device+2);}}}
    return result;
}
OSStatus sizeOf(AudioServerPlugInDriverRef driver,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32* size) {
    std::lock_guard lock(control);if(!has(driver,id,pid,a))return kAudioHardwareUnknownPropertyError;
    switch(a->mSelector){
        case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioObjectPropertyElementName:case kAudioPlugInPropertyBundleID:case kAudioPlugInPropertyResourceBundle:case kAudioDevicePropertyDeviceUID:case kAudioDevicePropertyModelUID:case MD_DRIVER_CONFIG_SELECTOR:*size=sizeof(CFTypeRef);break;
        case kAudioObjectPropertyOwnedObjects:case kAudioPlugInPropertyDeviceList:case kAudioDevicePropertyStreams:case kAudioObjectPropertyControlList:case kAudioDevicePropertyRelatedDevices:*size=UInt32(objects(id,a->mSelector,a->mScope).size()*sizeof(AudioObjectID));break;
        case kAudioObjectPropertyCustomPropertyInfoList:*size=sizeof(AudioServerPlugInCustomPropertyInfo);break;
        case kAudioDevicePropertyNominalSampleRate:*size=sizeof(Float64);break;
        case kAudioDevicePropertyAvailableNominalSampleRates:case kAudioDevicePropertyBufferFrameSizeRange:*size=sizeof(AudioValueRange);break;
        case kAudioDevicePropertyPreferredChannelsForStereo:*size=sizeof(UInt32)*2;break;
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:*size=sizeof(AudioStreamBasicDescription);break;
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:*size=sizeof(AudioStreamRangedDescription);break;
        case kAudioDevicePropertyStreamConfiguration:*size=sizeof(AudioBufferList);break;
        case kAudioDevicePropertyPreferredChannelLayout:*size=offsetof(AudioChannelLayout,mChannelDescriptions);break;
        default:*size=sizeof(UInt32);break;
    }return noErr;
}
OSStatus get(AudioServerPlugInDriverRef driver,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a,UInt32 qualifierSize,const void* qualifier,UInt32 size,UInt32* used,void* out) {
    std::lock_guard lock(control);if(!has(driver,id,pid,a))return kAudioHardwareUnknownPropertyError;
    auto o=object(id);bool plugin=id==kAudioObjectPlugInObject;UInt32 value=0;
    switch(a->mSelector){
        case kAudioObjectPropertyBaseClass:value=o.stream?kAudioObjectClassID:(plugin?kAudioObjectClassID:kAudioObjectClassID);break;
        case kAudioObjectPropertyClass:value=plugin?UInt32(kAudioPlugInClassID):(o.stream?UInt32(kAudioStreamClassID):UInt32(kAudioDeviceClassID));break;
        case kAudioObjectPropertyOwner:value=plugin?kAudioObjectUnknown:(o.stream?o.device:kAudioObjectPlugInObject);break;
        case kAudioObjectPropertyName:return string(plugin?@"Mixing Desk":(o.stream?(o.input?@"Input":@"Output"):(o.bridge?[o.pair->name stringByAppendingString:@" — Engine"]:o.pair->name)),size,used,out);
        case kAudioObjectPropertyElementName:return string([NSString stringWithFormat:@"Channel %u",a->mElement],size,used,out);
        case kAudioObjectPropertyManufacturer:return string(@"Mixing Desk",size,used,out);
        case kAudioPlugInPropertyBundleID:return string(@MD_DRIVER_BUNDLE_ID,size,used,out);
        case kAudioPlugInPropertyResourceBundle:return string(@"",size,used,out);
        case kAudioDevicePropertyDeviceUID:return string(o.bridge?[o.pair->uid stringByAppendingString:@".bridge"]:o.pair->uid,size,used,out);
        case kAudioDevicePropertyModelUID:return string(@"local.mixingdesk.duplex.v1",size,used,out);
        case kAudioObjectPropertyOwnedObjects:case kAudioPlugInPropertyDeviceList:case kAudioDevicePropertyStreams:case kAudioObjectPropertyControlList:case kAudioDevicePropertyRelatedDevices:return copyList(objects(id,a->mSelector,a->mScope),size,used,out);
        case kAudioPlugInPropertyTranslateUIDToDevice:{
            if(qualifierSize!=sizeof(CFStringRef)||!qualifier)return kAudioHardwareBadPropertySizeError;
            NSString* uid=(__bridge NSString*)*(CFStringRef*)qualifier;
            for(int i=0;i<allocated;++i)if(owned[i]->alive){if([uid isEqual:owned[i]->uid])value=owned[i]->base;else if([uid isEqual:[owned[i]->uid stringByAppendingString:@".bridge"]])value=owned[i]->base+4;}
            break;}
        case kAudioObjectPropertyCustomPropertyInfoList:{AudioServerPlugInCustomPropertyInfo info{MD_DRIVER_CONFIG_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};return copy(info,size,used,out);}
        case MD_DRIVER_CONFIG_SELECTOR:{if(size<sizeof(CFPropertyListRef))return kAudioHardwareBadPropertySizeError;CFPropertyListRef cf=(__bridge_retained CFPropertyListRef)configuration();return copy(cf,size,used,out);}
        case kAudioDevicePropertyTransportType:value=kAudioDeviceTransportTypeVirtual;break;
        case kAudioDevicePropertyClockDomain:value=0x4d44534b;break;
        case kAudioDevicePropertyDeviceIsAlive:case kAudioStreamPropertyIsActive:value=1;break;
        case kAudioDevicePropertyDeviceIsRunning:value=(o.bridge?o.pair->bridgeIO:o.pair->publicIO).load()>0;break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:value=!o.bridge;break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:value=0;break;
        case kAudioDevicePropertyLatency:value=o.stream?0:(a->mScope==kAudioObjectPropertyScopeInput?MD_DRIVER_LATENCY:0);break;
        case kAudioDevicePropertySafetyOffset:value=0;break;
        case kAudioDevicePropertyIsHidden:value=o.bridge;break;
        case kAudioDevicePropertyZeroTimeStampPeriod:value=MD_DRIVER_TIMESTAMP_PERIOD;break;
        case kAudioDevicePropertyClockAlgorithm:value=kAudioDeviceClockAlgorithmRaw;break;
        case kAudioDevicePropertyBufferFrameSize:value=(o.bridge?o.pair->bridgeFrames:o.pair->publicFrames).load();break;
        case kAudioDevicePropertyBufferFrameSizeRange:{AudioValueRange range{32,4096};return copy(range,size,used,out);}
        case kAudioDevicePropertyUsesVariableBufferFrameSizes:value=0;break;
        case kAudioDevicePropertyNominalSampleRate:return copy(Float64(MD_DRIVER_RATE),size,used,out);
        case kAudioDevicePropertyAvailableNominalSampleRates:{AudioValueRange range{MD_DRIVER_RATE,MD_DRIVER_RATE};return copy(range,size,used,out);}
        case kAudioDevicePropertyPreferredChannelsForStereo:{std::array<UInt32,2> stereo{1,UInt32(o.pair->channels>1?2:1)};return copy(stereo,size,used,out);}
        case kAudioDevicePropertyStreamConfiguration:{AudioBufferList buffers{1,{{UInt32(o.pair->channels),0,nullptr}}};return copy(buffers,size,used,out);}
        case kAudioDevicePropertyPreferredChannelLayout:{AudioChannelLayout layout{};layout.mChannelLayoutTag=o.pair->channels==1?kAudioChannelLayoutTag_Mono:(o.pair->channels==2?kAudioChannelLayoutTag_Stereo:(kAudioChannelLayoutTag_DiscreteInOrder|o.pair->channels));UInt32 len=offsetof(AudioChannelLayout,mChannelDescriptions);if(size<len)return kAudioHardwareBadPropertySizeError;memcpy(out,&layout,len);*used=len;return noErr;}
        case kAudioStreamPropertyDirection:value=o.input;break;
        case kAudioStreamPropertyTerminalType:value=o.input?kAudioStreamTerminalTypeMicrophone:kAudioStreamTerminalTypeSpeaker;break;
        case kAudioStreamPropertyStartingChannel:value=1;break;
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:return copy(format(o.pair->channels),size,used,out);
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:{AudioStreamRangedDescription range{format(o.pair->channels),{MD_DRIVER_RATE,MD_DRIVER_RATE}};return copy(range,size,used,out);}
        default:return kAudioHardwareUnknownPropertyError;
    }return copy(value,size,used,out);
}
OSStatus set(AudioServerPlugInDriverRef,AudioObjectID id,pid_t,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32 size,const void* data) {
    if(!data||!a)return kAudioHardwareIllegalOperationError;
    if(id==kAudioObjectPlugInObject && a->mSelector==MD_DRIVER_CONFIG_SELECTOR) {
        if(size!=sizeof(CFPropertyListRef))return kAudioHardwareBadPropertySizeError;
        NSDictionary* d=(__bridge NSDictionary*)*(CFPropertyListRef*)data;
        if(![d isKindOfClass:NSDictionary.class]||![d[@"version"] isKindOfClass:NSNumber.class]||[d[@"version"] doubleValue]!=MD_DRIVER_PROTOCOL_VERSION||![d[@"operation"] isKindOfClass:NSString.class])return kAudioHardwareIllegalOperationError;
        NSString* operation=d[@"operation"];OSStatus code=noErr;AudioObjectID renamed=0;
        {
            std::lock_guard lock(control);
            if([operation isEqual:@"create"])code=add(d);
            else {
                Pair* p=nullptr;int slot=0;for(;slot<allocated;++slot)if(owned[slot]->alive && [owned[slot]->uid isEqual:d[@"uid"]]){p=owned[slot].get();break;}
                if(!p)return kAudioHardwareBadObjectError;
                // HAL registers processes that merely enumerate a device. Only active
                // IO makes it busy; otherwise an idle device can never be deleted.
                if([operation isEqual:@"delete"]){if(p->publicIO||p->bridgeIO)return kAudioHardwareIllegalOperationError;p->alive=false;code=persist();if(code)p->alive=true;else{p->toApps.reset();p->fromApps.reset();}}
                else if([operation isEqual:@"rename"]){NSString* name=d[@"name"];if(![name isKindOfClass:NSString.class]||!name.length||name.length>128)return kAudioHardwareIllegalOperationError;NSString* old=p->name;p->name=[name copy];code=persist();if(code)p->name=old;else renamed=p->base;}
                else return kAudioHardwareIllegalOperationError;
            }
        }
        if(!code){notify(kAudioObjectPlugInObject,kAudioPlugInPropertyDeviceList);notify(kAudioObjectPlugInObject,kAudioObjectPropertyOwnedObjects);notify(kAudioObjectPlugInObject,MD_DRIVER_CONFIG_SELECTOR);if(renamed){notify(renamed,kAudioObjectPropertyName);notify(renamed+4,kAudioObjectPropertyName);}}
        return code;
    }
    auto o=object(id);if(!o.pair)return kAudioHardwareBadObjectError;
    switch(a->mSelector){
        case kAudioDevicePropertyNominalSampleRate:if(size!=sizeof(Float64))return kAudioHardwareBadPropertySizeError;return *(const Float64*)data==MD_DRIVER_RATE?OSStatus(noErr):OSStatus(kAudioHardwareUnsupportedOperationError);
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:{if(size!=sizeof(AudioStreamBasicDescription))return kAudioHardwareBadPropertySizeError;auto wanted=format(o.pair->channels);return memcmp(data,&wanted,sizeof(wanted))==0?OSStatus(noErr):OSStatus(kAudioDeviceUnsupportedFormatError);}
        case kAudioStreamPropertyIsActive:return noErr;
        case kAudioDevicePropertyBufferFrameSize:{if(size!=sizeof(UInt32))return kAudioHardwareBadPropertySizeError;UInt32 n=*(const UInt32*)data;if(n<32||n>4096)return kAudioHardwareIllegalOperationError;return host->RequestDeviceConfigurationChange(host,id,n,nullptr);}
        default:return kAudioHardwareUnknownPropertyError;
    }
}
OSStatus start(AudioServerPlugInDriverRef,AudioObjectID id,UInt32) {
    std::lock_guard lock(control);
    auto o=object(id);if(!o.pair)return kAudioHardwareBadObjectError;
    auto& count=o.bridge?o.pair->bridgeIO:o.pair->publicIO;
    // StartIO is a control operation; no writer runs before it returns.
    if(count.fetch_add(1)==0)(o.bridge?o.pair->toApps:o.pair->fromApps)->invalidate();
    return noErr;
}
OSStatus stop(AudioServerPlugInDriverRef,AudioObjectID id,UInt32) {std::lock_guard lock(control);auto o=object(id);if(!o.pair)return kAudioHardwareBadObjectError;auto& count=o.bridge?o.pair->bridgeIO:o.pair->publicIO;UInt32 n=count.load();while(n && !count.compare_exchange_weak(n,n-1)){}return noErr;}
OSStatus timestamp(AudioServerPlugInDriverRef,AudioObjectID id,UInt32,Float64* sample,UInt64* time,UInt64* seed) {if(!object(id).pair)return kAudioHardwareBadObjectError;uint64_t now=mach_absolute_time();uint64_t frames=uint64_t(double(now-epoch)/ticksPerFrame)/MD_DRIVER_TIMESTAMP_PERIOD*MD_DRIVER_TIMESTAMP_PERIOD;*sample=double(frames);*time=epoch+uint64_t(frames*ticksPerFrame);*seed=1;return noErr;}
OSStatus will(AudioServerPlugInDriverRef,AudioObjectID,UInt32,UInt32 op,Boolean* doIt,Boolean* inPlace) {*doIt=op==kAudioServerPlugInIOOperationReadInput||op==kAudioServerPlugInIOOperationWriteMix;*inPlace=true;return noErr;}
OSStatus begin(AudioServerPlugInDriverRef,AudioObjectID,UInt32,UInt32,UInt32,const AudioServerPlugInIOCycleInfo*) {return noErr;}
OSStatus io(AudioServerPlugInDriverRef,AudioObjectID id,AudioObjectID,UInt32,UInt32 op,UInt32 frames,const AudioServerPlugInIOCycleInfo* cycle,void* main,void*) {
    auto o=object(id);if(!o.pair||!main||frames>4096)return kAudioHardwareIllegalOperationError;
    auto& pair=*o.pair;auto* data=(float*)main;
    if(op==kAudioServerPlugInIOOperationWriteMix)(o.bridge?pair.toApps:pair.fromApps)->write(int64_t(cycle->mOutputTime.mSampleTime),data,frames);
    else if(op==kAudioServerPlugInIOOperationReadInput){
        if((o.bridge?pair.publicIO:pair.bridgeIO).load()==0)memset(main,0,frames*pair.channels*sizeof(float));
        else (o.bridge?pair.fromApps:pair.toApps)->read(int64_t(cycle->mInputTime.mSampleTime)-MD_DRIVER_LATENCY,data,frames);
    }return noErr;
}
AudioServerPlugInDriverInterface interface={nullptr,query,retain,release,initialize,create,destroy,addClient,removeClient,perform,abortChange,has,settable,sizeOf,get,set,start,stop,timestamp,will,begin,io,begin};
AudioServerPlugInDriverInterface* interfacePointer=&interface;
HRESULT query(void*,REFIID uuid,LPVOID* result) {
    if(!result)return E_POINTER;CFUUIDRef requested=CFUUIDCreateFromUUIDBytes(nullptr,uuid);
    bool valid=CFEqual(requested,IUnknownUUID)||CFEqual(requested,kAudioServerPlugInDriverInterfaceUUID);CFRelease(requested);
    if(!valid){*result=nullptr;return E_NOINTERFACE;}*result=&interfacePointer;++references;return S_OK;
}
}
extern "C" __attribute__((visibility("default"))) void* MixingDeskDriverFactory(CFAllocatorRef,CFUUIDRef type) {
    return CFEqual(type,kAudioServerPlugInTypeUUID)?&interfacePointer:nullptr;
}
