#import "PluginHost.hpp"
#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <CoreAudioKit/AUGenericView.h>
#import <objc/runtime.h>
#include <array>
#include <algorithm>
#include <set>
#include <cstring>
#include <atomic>
#include <cmath>
#include <map>
#include <memory>
#include <stdexcept>

namespace {
constexpr UInt32 Capacity=4096;
void onMainThread(dispatch_block_t action) {
    if(NSThread.isMainThread)action();
    else dispatch_sync(dispatch_get_main_queue(),action);
}
NSString* componentID(AudioComponentDescription d) {
    return [NSString stringWithFormat:@"%08x:%08x:%08x",(unsigned)d.componentType,(unsigned)d.componentSubType,(unsigned)d.componentManufacturer];
}
bool description(NSString* value,AudioComponentDescription& d) {
    unsigned type=0,sub=0,manufacturer=0;char extra=0;
    if(sscanf(value.UTF8String ?: "","%8x:%8x:%8x%c",&type,&sub,&manufacturer,&extra)!=3)return false;
    d={type,sub,manufacturer,0,0};
    return (type==kAudioUnitType_Effect||type==kAudioUnitType_MusicEffect) && [componentID(d) isEqual:value];
}
NSString* componentName(AudioComponent component) {
    CFStringRef name=nullptr;AudioComponentCopyName(component,&name);
    return name ? CFBridgingRelease(name) : @"Audio Unit";
}
void check(OSStatus code,const char* operation) {
    if(code)throw std::runtime_error(std::string(operation)+" ("+std::to_string(code)+")");
}
struct StereoList { UInt32 count=2;AudioBuffer buffers[2]{};AudioBufferList* list(){return reinterpret_cast<AudioBufferList*>(this);} };
class AudioUnitProcessor final : public desk::HostedProcessor {
    AudioUnit unit_=nullptr;
    UInt32 inputChannels_=2,outputChannels_=2;
    std::array<float,Capacity*6> buffers_{};
    const float* input_[2]{};
    UInt32 frames_=0;
    double time_=0;
    float mix_=0,target_=1;
    bool mono_;
    std::atomic<OSStatus> renderError_{0};
    static OSStatus pull(void* context,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32 bus,UInt32 frames,AudioBufferList* output) {
        auto& p=*static_cast<AudioUnitProcessor*>(context);
        if(bus!=0 || frames>p.frames_ || output->mNumberBuffers!=p.inputChannels_)return kAudioUnitErr_TooManyFramesToProcess;
        for(UInt32 c=0;c<p.inputChannels_;++c) {
            auto& b=output->mBuffers[c];b.mNumberChannels=1;b.mDataByteSize=frames*sizeof(float);
            if(b.mData)memcpy(b.mData,p.input_[c],b.mDataByteSize);
            else b.mData=const_cast<float*>(p.input_[c]);
        }return noErr;
    }
public:
    AudioUnitProcessor(NSString* identifier,NSData* state,bool mono):mono_(mono) {
        // AU constructors can initialize a vendor's UI/message-thread runtime,
        // even before an editor is requested. Do not bind it to our control queue.
        onMainThread(^{
        try {
            AudioComponentDescription d{};
            if(!description(identifier,d))throw std::runtime_error("Invalid Audio Unit identifier");
            AudioComponent component=AudioComponentFindNext(nullptr,&d);
            if(!component)throw std::runtime_error("Not installed for this Mac. Install the Apple Silicon Audio Unit using the vendor installer, then reload the session.");
            AudioComponentDescription actual{};AudioComponentGetDescription(component,&actual);
            if(actual.componentFlags & kAudioComponentFlag_IsV3AudioUnit)throw std::runtime_error("This version hosts AUv2 effects. AUv3 hosting is not available yet.");
            name=componentName(component);
            check(AudioComponentInstanceNew(component,&unit_),"Could not load Audio Unit");
            if(state.length)restoreData(state);
            prepare(48000,Capacity,2);
        } catch(const std::exception& e) {
            failure=[NSString stringWithUTF8String:e.what()];mix_=1;
            if(unit_){AudioUnitUninitialize(unit_);AudioComponentInstanceDispose(unit_);unit_=nullptr;}
        }
        });
    }
    ~AudioUnitProcessor() { onMainThread(^{if(unit_){AudioUnitUninitialize(unit_);AudioComponentInstanceDispose(unit_);}}); }
    bool available()const override {return unit_!=nullptr;}
    NSView* makeView() override;
    bool monoInput()const override {return inputChannels_==1;}
    int32_t renderError()const override {return renderError_.load(std::memory_order_relaxed);}
    void prepare(double rate,uint32_t maximum,uint32_t channels) override {
        if(channels!=2||maximum>Capacity)throw std::runtime_error("Unsupported render format");
        UInt32 count=maximum;
        check(AudioUnitSetProperty(unit_,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&count,sizeof(count)),"Maximum buffer size");
        AURenderCallbackStruct callback{pull,this};
        check(AudioUnitSetProperty(unit_,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback)),"Input callback");
        const std::array<std::pair<int,int>,3> layouts{{{1,2},{1,1},{2,2}}};
        OSStatus formatError=kAudioUnitErr_FormatNotSupported;
        for(size_t i=mono_?0:2;i<layouts.size();++i) {
            auto pair=layouts[i];
            AudioStreamBasicDescription f{rate,kAudioFormatLinearPCM,UInt32(kAudioFormatFlagsNativeFloatPacked)|UInt32(kAudioFormatFlagIsNonInterleaved),4,1,4,(UInt32)pair.first,32,0};
            auto a=AudioUnitSetProperty(unit_,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&f,sizeof(f));
            f.mChannelsPerFrame=pair.second;
            auto b=AudioUnitSetProperty(unit_,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&f,sizeof(f));
            if(a||b){formatError=a?a:b;continue;}
            inputChannels_=pair.first;outputChannels_=pair.second;
            // AUv2 units may accept each stream format independently and only
            // validate the input/output channel pair during initialization.
            // A mono source therefore needs the same fallback at this stage.
            auto initialized=AudioUnitInitialize(unit_);
            if(!initialized)return;
            AudioUnitUninitialize(unit_);
            if(initialized!=kAudioUnitErr_FormatNotSupported)check(initialized,"Audio Unit initialization");
            formatError=initialized;
        }
        check(formatError,"This Audio Unit does not support the channel's 48 kHz mono/stereo layouts. Try a mono source for a mono-only plugin.");
    }
    void process(float* const* audio,uint32_t channels,uint32_t frames) noexcept override {
        if(channels!=2||frames>Capacity)return;
        frames_=frames;
        for(UInt32 c=0;c<2;++c) {
            memcpy(buffers_.data()+(2+c)*Capacity,audio[c],frames*sizeof(float));
            memcpy(buffers_.data()+(4+c)*Capacity,audio[c],frames*sizeof(float));
            input_[c]=buffers_.data()+(4+c)*Capacity;
        }
        StereoList output;output.count=outputChannels_;
        for(UInt32 c=0;c<outputChannels_;++c){std::fill_n(buffers_.data()+c*Capacity,frames,0.f);output.buffers[c]={1,frames*UInt32(sizeof(float)),buffers_.data()+c*Capacity};}
        AudioTimeStamp stamp{};stamp.mSampleTime=time_;stamp.mFlags=kAudioTimeStampSampleTimeValid;time_+=frames;
        AudioUnitRenderActionFlags flags=0;
        OSStatus error=unit_ ? AudioUnitRender(unit_,&flags,&stamp,0,frames,output.list()) : -1;
        renderError_.store(error,std::memory_order_relaxed);
        for(UInt32 f=0;f<frames;++f) {
            mix_+=std::clamp(target_-mix_,-1.f/240,1.f/240);
            for(UInt32 c=0;c<2;++c) {
                const auto& b=output.buffers[std::min(c,outputChannels_-1)];
                float wet=(!error && !(flags & kAudioUnitRenderAction_OutputIsSilence) && b.mData && b.mDataByteSize>=(f+1)*sizeof(float)) ? static_cast<const float*>(b.mData)[f] : 0;
                if(!std::isfinite(wet))wet=0;
                audio[c][f]=buffers_[(2+c)*Capacity+f]*(1-mix_)+wet*mix_;
            }
        }
    }
    // AudioUnitReset can enter plugin code that is not real-time safe. The rack
    // invokes resetStopped only after IO has stopped; render-side reset is empty.
    void reset() noexcept override {}
    void resetStopped() override {time_=0;renderError_=0;if(unit_)AudioUnitReset(unit_,kAudioUnitScope_Global,0);}
    void setBypassed(bool value) noexcept override {target_=value?0:1;}
    uint32_t latencyFrames() const noexcept override {
        Float64 seconds=0;UInt32 size=sizeof(seconds);
        if(!unit_||AudioUnitGetProperty(unit_,kAudioUnitProperty_Latency,kAudioUnitScope_Global,0,&seconds,&size)||!std::isfinite(seconds))return 0;
        return uint32_t(std::clamp(seconds*48000.,0.,4800000.));
    }
    NSData* data() const override {
        if(!unit_)return nil;
        CFPropertyListRef property=nullptr;UInt32 size=sizeof(property);
        if(AudioUnitGetProperty(unit_,kAudioUnitProperty_ClassInfo,kAudioUnitScope_Global,0,&property,&size)||!property)return nil;
        id state=CFBridgingRelease(property);
        NSData* bytes=[NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        return bytes.length<=16*1024*1024 ? bytes : nil;
    }
    void restoreData(NSData* bytes) {
        if(bytes.length>16*1024*1024)throw std::runtime_error("Plugin state exceeds 16 MB");
        id value=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];
        if(![value isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid Audio Unit preset state");
        CFPropertyListRef property=(__bridge CFPropertyListRef)value;
        check(AudioUnitSetProperty(unit_,kAudioUnitProperty_ClassInfo,kAudioUnitScope_Global,0,&property,sizeof(property)),"Could not restore plugin settings");
    }
    std::vector<uint8_t> saveState()const override {NSData* d=data();if(!d)return {};auto p=static_cast<const uint8_t*>(d.bytes);return {p,p+d.length};}
    void restoreState(const std::vector<uint8_t>& bytes)override {restoreData([NSData dataWithBytes:bytes.data() length:bytes.size()]);}
};
NSView* AudioUnitProcessor::makeView() {
    NSCAssert(NSThread.isMainThread,@"Audio Unit editors must be opened on the main thread");
    AudioUnit unit=unit_;if(!unit)return nil;
    UInt32 size=0;Boolean writable=false;
    if(!AudioUnitGetPropertyInfo(unit,kAudioUnitProperty_CocoaUI,kAudioUnitScope_Global,0,&size,&writable) && size>=sizeof(AudioUnitCocoaViewInfo)) {
        std::vector<uint8_t> bytes(size);auto info=reinterpret_cast<AudioUnitCocoaViewInfo*>(bytes.data());
        if(!AudioUnitGetProperty(unit,kAudioUnitProperty_CocoaUI,kAudioUnitScope_Global,0,info,&size)) {
            NSBundle* bundle=[NSBundle bundleWithURL:(__bridge NSURL*)info->mCocoaAUViewBundleLocation];[bundle load];
            NSUInteger count=(size-sizeof(CFURLRef))/sizeof(CFStringRef);NSView* view=nil;
            for(NSUInteger i=0;i<count&&!view;++i) {
                Class cls=[bundle classNamed:(__bridge NSString*)info->mCocoaAUViewClass[i]];
                if([cls conformsToProtocol:@protocol(AUCocoaUIBase)]) {id<AUCocoaUIBase> factory=[[cls alloc] init];view=[factory uiViewForAudioUnit:unit withSize:NSMakeSize(760,500)];}
            }
            if(info->mCocoaAUViewBundleLocation)CFRelease(info->mCocoaAUViewBundleLocation);
            for(NSUInteger i=0;i<count;++i)if(info->mCocoaAUViewClass[i])CFRelease(info->mCocoaAUViewClass[i]);
            if(view) {
                // The native view can outlive its window controller during
                // AppKit teardown. Keep the Audio Unit alive until that view
                // has disposed its parameter listeners and other resources.
                return view;
            }
        }
    }
    NSView* view=[[AUGenericView alloc] initWithAudioUnit:unit];
    return view;
}
}

std::shared_ptr<desk::HostedProcessor> desk::makeAudioUnit(NSString* identifier,NSData* state,bool mono) {
    return std::make_shared<AudioUnitProcessor>(identifier,state,mono);
}

NSArray* desk::audioUnitCatalog() {
    NSMutableArray* result=[NSMutableArray array];
    for(auto type:{kAudioUnitType_Effect,kAudioUnitType_MusicEffect}) {
        AudioComponentDescription filter{type,0,0,0,0};AudioComponent component=nullptr;
        while((component=AudioComponentFindNext(component,&filter))) {
            AudioComponentDescription d{};AudioComponentGetDescription(component,&d);
            // AUv2 Cocoa editors and synchronous loading are supported initially.
            if(d.componentFlags & kAudioComponentFlag_IsV3AudioUnit)continue;
            NSString* full=componentName(component);NSRange colon=[full rangeOfString:@": "];
            NSString* vendor=colon.location==NSNotFound ? @"Audio Unit" : [full substringToIndex:colon.location];
            NSString* name=colon.location==NSNotFound ? full : [full substringFromIndex:colon.location+2];
            [result addObject:@{@"id":componentID(d),@"format":@"au",@"name":name,@"manufacturer":vendor}];
        }
    }
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b){return [[a[@"manufacturer"] stringByAppendingString:a[@"name"]] localizedCaseInsensitiveCompare:[b[@"manufacturer"] stringByAppendingString:b[@"name"]]];}];
}
