#import "PluginHost.hpp"
#include "VST3Support.hpp"
#include <array>
#include <cmath>
#include <functional>
#include <stdexcept>
#include <set>
#include <signal.h>
#include <unistd.h>

using namespace desk::vst3;
namespace {
constexpr uint32_t Capacity=4096;
void mainThread(const std::function<void()>& action) {
    if(NSThread.isMainThread){action();return;}
    __block std::exception_ptr failure;
    dispatch_sync(dispatch_get_main_queue(),^{try{action();}catch(...){failure=std::current_exception();}});
    if(failure)std::rethrow_exception(failure);
}
void check(tresult result,const char* message){if(result!=kResultOk)throw std::runtime_error(std::string(message)+" ("+std::to_string(result)+")");}
NSString* string(const char* s){return [NSString stringWithUTF8String:s] ?: @"";}
NSString* string16(const char16_t* s,size_t capacity=128){size_t n=0;while(n<capacity&&s[n])++n;return [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar*>(s) length:n];}
NSString* classID(const TUID cid){char value[33]{};FUID::fromTUID(cid).toString(value);return string(value);}
bool validID(NSString* id){return id.length==32 && [id rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet]].location==NSNotFound;}
Host host;
struct Module {
    CFBundleRef bundle=nullptr;
    IPluginFactory* factory=nullptr;
    bool entered=false;
    using Entry=bool(*)(CFBundleRef);using Exit=bool(*)();
    Module(NSString* path){
        bundle=CFBundleCreate(kCFAllocatorDefault,(__bridge CFURLRef)[NSURL fileURLWithPath:path]);
        if(!bundle)return;
        auto entry=reinterpret_cast<Entry>(CFBundleGetFunctionPointerForName(bundle,CFSTR("bundleEntry")));
        auto exit=CFBundleGetFunctionPointerForName(bundle,CFSTR("bundleExit"));
        auto get=reinterpret_cast<IPluginFactory*(*)()>(CFBundleGetFunctionPointerForName(bundle,CFSTR("GetPluginFactory")));
        if(!entry||!exit||!get||!(entered=entry(bundle)))return;
        factory=get();
        if(auto f=query<IPluginFactory3>(factory)){f->setHostContext(&host);f->release();}
    }
    ~Module(){release(factory);if(bundle){if(entered){auto exit=reinterpret_cast<Exit>(CFBundleGetFunctionPointerForName(bundle,CFSTR("bundleExit")));if(exit)exit();}CFRelease(bundle);}}
};
// Module entry/exit is reference counted across effect instances. macOS keeps
// the executable resident: unloading Cocoa code can invalidate vendor globals.
std::map<std::string,std::weak_ptr<Module>> modules; // main thread only
std::map<std::string,std::string> locations;
bool scanned=false;
std::shared_ptr<Module> module(NSString* path){auto& cached=modules[path.UTF8String];if(auto existing=cached.lock())return existing;auto value=std::make_shared<Module>(path);cached=value;return value;}
NSArray* inspectBundle(NSString* path){
    NSMutableArray* result=[NSMutableArray array];
    auto loaded=module(path);if(!loaded->factory)return result;
    auto f=query<IPluginFactory2>(loaded->factory);if(!f)return result;
    PFactoryInfo vendor{};f->getFactoryInfo(&vendor);
    for(int32 i=0;i<std::min<int32>(f->countClasses(),4096);++i){
        PClassInfo2 info{};if(f->getClassInfo2(i,&info)!=kResultOk||strcmp(info.category,kVstAudioEffectClass))continue;
        std::string categories=std::string("|")+info.subCategories+"|";
        if(categories.find("|Fx|")==std::string::npos)continue;
        [result addObject:@{@"id":classID(info.cid),@"format":@"vst3",@"name":string(info.name),@"manufacturer":string(info.vendor[0]?info.vendor:vendor.vendor)}];
    }f->release();return result;
}
NSArray* probeBundle(NSURL* bundle){
    NSURL* output=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[@"mixingdesk-vst3-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(![NSData.data writeToURL:output options:NSDataWritingWithoutOverwriting error:nil])return @[];
    NSArray* result=@[];
    @try {
        NSTask* task=[NSTask new];
        task.executableURL=NSBundle.mainBundle.executableURL ?: [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
        task.arguments=@[@"--desk-scan-vst3",bundle.path,output.path];
        task.standardOutput=NSFileHandle.fileHandleWithNullDevice;task.standardError=NSFileHandle.fileHandleWithNullDevice;
        if([task launchAndReturnError:nil]){
            NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
            while(task.running&&deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.02];
            if(task.running){[task terminate];NSDate* grace=[NSDate dateWithTimeIntervalSinceNow:.3];while(task.running&&grace.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.01];if(task.running)kill(task.processIdentifier,SIGKILL);}
            [task waitUntilExit];
            NSNumber* size=nil;[output getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            if(task.terminationStatus==0&&size.unsignedLongLongValue<=1024*1024){
                NSData* bytes=[NSData dataWithContentsOfURL:output];
                id value=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
                if([value isKindOfClass:NSArray.class])result=value;
            }
        }
    } @finally {[NSFileManager.defaultManager removeItemAtURL:output error:nil];}
    return result;
}
NSArray* scan(){
    NSMutableArray* result=[NSMutableArray array];std::set<std::string> seen;locations.clear();scanned=true;
    NSArray* roots=@[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/VST3"],@"/Library/Audio/Plug-Ins/VST3"];
#ifdef MD_PLUGIN_TESTS
    if(const char* path=getenv("MD_VST3_TEST_PATH"))roots=@[string(path)];
#endif
    for(NSString* root in roots){
        auto enumerator=[NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        NSMutableArray<NSURL*>* paths=[NSMutableArray array];
        for(NSURL* url in enumerator)if([url.pathExtension.lowercaseString isEqual:@"vst3"]){[paths addObject:url];[enumerator skipDescendants];}
        [paths sortUsingComparator:^NSComparisonResult(NSURL* a,NSURL* b){return [a.path compare:b.path];}];
        for(NSURL* url in paths)for(id item in probeBundle(url)){
            if(![item isKindOfClass:NSDictionary.class]||![item[@"id"] isKindOfClass:NSString.class]||!validID(item[@"id"])||![item[@"name"] isKindOfClass:NSString.class]||![item[@"manufacturer"] isKindOfClass:NSString.class])continue;
            NSString* id=item[@"id"];if(!seen.insert(id.UTF8String).second)continue;
            locations[id.UTF8String]=url.path.UTF8String;
            [result addObject:@{@"id":id,@"format":@"vst3",@"name":item[@"name"],@"manufacturer":item[@"manufacturer"]}];
        }
    }return result;
}
class VST3Processor;
class Handler final:public IComponentHandler {
    std::atomic<uint32> refs{1};
public:
    VST3Processor* owner=nullptr;
    uint32 PLUGIN_API addRef()override{return ++refs;}
    uint32 PLUGIN_API release()override{auto n=--refs;if(!n)delete this;return n;}
    tresult PLUGIN_API queryInterface(const TUID id,void** out)override{
        if(!out)return kInvalidArgument;*out=nullptr;
        if(FUnknownPrivate::iidEqual(id,IComponentHandler::iid)||FUnknownPrivate::iidEqual(id,FUnknown::iid)){*out=this;addRef();return kResultOk;}return kNoInterface;
    }
    tresult PLUGIN_API beginEdit(ParamID)override{return kResultOk;}
    tresult PLUGIN_API performEdit(ParamID,ParamValue)override;
    tresult PLUGIN_API endEdit(ParamID)override{return kResultOk;}
    tresult PLUGIN_API restartComponent(int32)override;
};
class VST3Processor final:public desk::HostedProcessor {
    std::shared_ptr<Module> module_;
    IComponent* component_=nullptr;
    IAudioProcessor* processor_=nullptr;
    IEditController* controller_=nullptr;
    IConnectionPoint* componentConnection_=nullptr;IConnectionPoint* controllerConnection_=nullptr;
    bool initialized_=false,controllerInitialized_=false,active_=false,processing_=false,mono_=false;
    int32 inputChannels_=2,outputChannels_=2;
    std::vector<AudioBusBuffers> inputs_,outputs_;
    std::array<float,Capacity*6> buffers_{};
    float* inputPointers_[2]{buffers_.data(),buffers_.data()+Capacity};
    float* outputPointers_[2]{buffers_.data()+Capacity*2,buffers_.data()+Capacity*3};
    Changes inputChanges_,outputChanges_;Events events_;
    std::unique_ptr<Parameter[]> parameters_;int32 parameterCount_=0;
    Handler* handler_=new Handler;
    std::atomic<int32> error_{0},restart_{0};
    std::atomic<uint32_t> latency_{0};
    std::atomic<bool> suspended_{false};
    bool needsReload_=false;
    std::atomic<uint32_t> rendering_{0};
    int64 sampleTime_=0;
    float mix_=0,target_=1;
    NSString* identifier_;
    void close(){
        if(processing_){processor_->setProcessing(false);processing_=false;}
        if(active_){component_->setActive(false);active_=false;}
        if(controller_)controller_->setComponentHandler(nullptr);handler_->owner=nullptr;
        if(componentConnection_&&controllerConnection_){componentConnection_->disconnect(controllerConnection_);controllerConnection_->disconnect(componentConnection_);}
        // Keep every interface alive until both halves have terminated: a
        // controller may still be referenced during component shutdown.
        if(controllerInitialized_){controller_->terminate();controllerInitialized_=false;}
        if(initialized_){component_->terminate();initialized_=false;}
        // A vendor may have already posted controller notifications to the
        // main queue. Terminate now, but retire interface references on the
        // following main-queue turn so those notifications can finish safely.
        auto componentConnection=componentConnection_;auto controllerConnection=controllerConnection_;
        auto processor=processor_;auto component=component_;auto controller=controller_;auto module=module_;
        componentConnection_=nullptr;controllerConnection_=nullptr;processor_=nullptr;component_=nullptr;controller_=nullptr;module_.reset();
        dispatch_async(dispatch_get_main_queue(),^{
            if(componentConnection)componentConnection->release();if(controllerConnection)controllerConnection->release();
            if(processor)processor->release();if(component)component->release();if(controller)controller->release();
            (void)module; // Captured to keep the factory alive through release.
        });
    }
    void enumerateParameters(){
        parameterCount_=controller_?controller_->getParameterCount():0;
        if(parameterCount_<0||parameterCount_>32768)throw std::runtime_error("Unsupported VST3 parameter count");
        parameters_=std::make_unique<Parameter[]>(parameterCount_);
        for(int32 i=0;i<parameterCount_;++i){ParameterInfo info{};check(controller_->getParameterInfo(i,info),"VST3 parameter information");parameters_[i].id=info.id;parameters_[i].flags=info.flags;}
        inputChanges_.prepare(parameterCount_);outputChanges_.prepare(parameterCount_);
    }
    void syncParameters(){if(controller_)for(int32 i=0;i<parameterCount_;++i)if(!(parameters_[i].flags&ParameterInfo::kIsReadOnly))edit(parameters_[i].id,controller_->getParamNormalized(parameters_[i].id));}
    void restoreData(NSData* bytes){
        if(!bytes.length)return;
        if(bytes.length>StateLimit)throw std::runtime_error("VST3 state exceeds 16 MB");
        NSDictionary* state=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];
        if(![state isKindOfClass:NSDictionary.class]||![state[@"version"] isEqual:@1]||![state[@"classID"] isEqual:identifier_]||![state[@"component"] isKindOfClass:NSData.class])throw std::runtime_error("Invalid or mismatched VST3 state");
        NSData* component=state[@"component"];Stream stream(component.bytes,component.length);
        check(component_->setState(&stream),"Could not restore VST3 processor state");stream.rewind();
        if(controller_){
            controller_->setComponentState(&stream);
            if(NSData* control=state[@"controller"]){if(![control isKindOfClass:NSData.class])throw std::runtime_error("Invalid VST3 controller state");Stream s(control.bytes,control.length);check(controller_->setState(&s),"Could not restore VST3 controller state");}
        }
        id values=state[@"parameters"];
        if(values&&![values isKindOfClass:NSArray.class])throw std::runtime_error("Invalid VST3 parameter state");
        for(id item in values){
            if(![item isKindOfClass:NSDictionary.class]||![item[@"id"] isKindOfClass:NSNumber.class]||![item[@"value"] isKindOfClass:NSNumber.class])throw std::runtime_error("Invalid VST3 parameter value");
            auto value=[item[@"value"] doubleValue];if(!std::isfinite(value)||value<0||value>1)throw std::runtime_error("Invalid VST3 normalized value");
            if(controller_){auto id=[item[@"id"] unsignedIntValue];if(controller_->getParamNormalized(id)!=value)controller_->setParamNormalized(id,value);edit(id,value);}
        }
    }
public:
    VST3Processor(NSString* identifier,NSData* state,bool mono):mono_(mono),identifier_(identifier){
        handler_->owner=this;name=@"VST3 effect";
        mainThread([&]{try{
            if(!validID(identifier))throw std::runtime_error("Invalid VST3 class identifier");
            auto found=locations.find(identifier.UTF8String);
            if(found==locations.end())throw std::runtime_error("VST3 effect is not installed. Install its Apple Silicon VST3 version, rescan, then reload.");
            module_=module(string(found->second.c_str()));
            if(!module_->factory)throw std::runtime_error("Cannot load VST3 bundle for this Mac");
            FUID cid;cid.fromString(identifier.UTF8String);
            for(int32 i=0;i<module_->factory->countClasses();++i){PClassInfo info{};if(module_->factory->getClassInfo(i,&info)==kResultOk&&classID(info.cid)&&[classID(info.cid) isEqual:identifier]){name=string(info.name);break;}}
            check(module_->factory->createInstance(cid.toTUID(),IComponent::iid.toTUID(),reinterpret_cast<void**>(&component_)),"Could not create VST3 effect");
            TUID controllerID{};bool hasControllerID=component_->getControllerClassId(controllerID)==kResultOk;
            component_->setIoMode(kSimple);check(component_->initialize(&host),"VST3 initialization");initialized_=true;
            processor_=query<IAudioProcessor>(component_);if(!processor_)throw std::runtime_error("VST3 has no audio processor");
            controller_=query<IEditController>(component_);
            if(!controller_){if(hasControllerID){check(module_->factory->createInstance(controllerID,IEditController::iid.toTUID(),reinterpret_cast<void**>(&controller_)),"Could not create VST3 controller");check(controller_->initialize(&host),"VST3 controller initialization");controllerInitialized_=true;}}
            if(controller_){
                controller_->setComponentHandler(handler_);
                componentConnection_=query<IConnectionPoint>(component_);controllerConnection_=query<IConnectionPoint>(controller_);
                if(componentConnection_&&controllerConnection_){componentConnection_->connect(controllerConnection_);controllerConnection_->connect(componentConnection_);}
                Stream initial;if(component_->getState(&initial)==kResultOk&&!initial.failed){initial.rewind();controller_->setComponentState(&initial);}
            }
            enumerateParameters();restoreData(state);prepare(48000,Capacity,2);restart_=0;
        }catch(const std::exception& e){failure=string(e.what());mix_=1;close();}});
    }
    ~VST3Processor(){mainThread([&]{close();handler_->release();});}
    bool available()const override{return component_!=nullptr;}
    bool monoInput()const override{return inputChannels_==1;}
    int32_t renderError()const override{return error_.load();}
    uint32_t latencyFrames()const noexcept override{return latency_.load();}
    void prepare(double rate,uint32_t maximum,uint32_t channels)override {
        if(rate!=48000||maximum>Capacity||channels!=2)throw std::runtime_error("Unsupported VST3 render format");
        check(processor_->canProcessSampleSize(kSample32),"VST3 requires Float32 processing");
        int32 ins=component_->getBusCount(kAudio,kInput),outs=component_->getBusCount(kAudio,kOutput);
        if(ins<1||outs<1||ins>32||outs>32)throw std::runtime_error("VST3 must be an audio effect with a main input and output");
        std::vector<SpeakerArrangement> input(ins,SpeakerArr::kEmpty),output(outs,SpeakerArr::kEmpty);
        bool configured=false;
        for(auto pair:mono_?std::array<std::pair<int,int>,3>{{{1,2},{1,1},{2,2}}}:std::array<std::pair<int,int>,3>{{{2,2},{2,2},{2,2}}}){
            input[0]=pair.first==1?SpeakerArr::kMono:SpeakerArr::kStereo;output[0]=pair.second==1?SpeakerArr::kMono:SpeakerArr::kStereo;
            if(processor_->setBusArrangements(input.data(),ins,output.data(),outs)==kResultOk){inputChannels_=pair.first;outputChannels_=pair.second;configured=true;break;}
        }
        if(!configured)throw std::runtime_error("VST3 does not support this mono/stereo layout. Try a mono source for a mono-only effect.");
        inputs_.resize(ins);outputs_.resize(outs);
        ProcessSetup setup{kRealtime,kSample32,int32(maximum),rate};check(processor_->setupProcessing(setup),"VST3 process setup");
        for(auto direction:{kInput,kOutput}){
            int32 count=direction==kInput?ins:outs;
            for(int32 i=0;i<count;++i){BusInfo info{};check(component_->getBusInfo(kAudio,direction,i,info),"VST3 bus information");if(i==0&&(info.busType!=kMain||info.channelCount!=(direction==kInput?inputChannels_:outputChannels_)))throw std::runtime_error("Unsupported VST3 main bus layout");check(component_->activateBus(kAudio,direction,i,i==0),"VST3 bus activation");}
            for(int32 i=0;i<component_->getBusCount(kEvent,direction);++i)component_->activateBus(kEvent,direction,i,false);
        }
        inputs_[0].numChannels=inputChannels_;inputs_[0].channelBuffers32=inputPointers_;
        outputs_[0].numChannels=outputChannels_;outputs_[0].channelBuffers32=outputPointers_;
        check(component_->setActive(true),"VST3 activation");active_=true;
        // Some valid processors leave the optional setProcessing method unimplemented.
        auto result=processor_->setProcessing(true);if(result!=kResultOk&&result!=kNotImplemented)check(result,"VST3 start processing");processing_=true;
        latency_=processor_->getLatencySamples();
    }
    void process(float* const* audio,uint32_t channels,uint32_t frames)noexcept override {
        if(channels!=2||frames>Capacity)return;
        rendering_.fetch_add(1,std::memory_order_seq_cst);
        bool ready=processor_&&!suspended_.load(std::memory_order_seq_cst);
        for(uint32_t c=0;c<2;++c){memcpy(buffers_.data()+(4+c)*Capacity,audio[c],frames*sizeof(float));memcpy(inputPointers_[c],audio[c],frames*sizeof(float));std::fill_n(outputPointers_[c],frames,0.f);}
        tresult result=kResultFalse;
        if(ready){
            inputChanges_.clear();outputChanges_.clear();
            for(int32 i=0;i<parameterCount_;++i)if(parameters_[i].inputDirty.exchange(false,std::memory_order_acquire)){
                int32 index=0;auto q=inputChanges_.addParameterData(parameters_[i].id,index);if(q)q->addPoint(0,parameters_[i].input.load(),index);
            }
            inputs_[0].silenceFlags=0;outputs_[0].silenceFlags=0;
            ProcessContext context{};context.sampleRate=48000;context.projectTimeSamples=sampleTime_;context.continousTimeSamples=sampleTime_;context.state=ProcessContext::kPlaying|ProcessContext::kContTimeValid;
            ProcessData data;data.processMode=kRealtime;data.symbolicSampleSize=kSample32;data.numSamples=frames;
            data.numInputs=int32(inputs_.size());data.numOutputs=int32(outputs_.size());data.inputs=inputs_.data();data.outputs=outputs_.data();data.inputParameterChanges=&inputChanges_;data.outputParameterChanges=&outputChanges_;data.inputEvents=&events_;data.outputEvents=&events_;data.processContext=&context;
            try{result=processor_->process(data);}catch(...){result=kInternalError;}
            for(int32 q=0;q<outputChanges_.getParameterCount();++q){auto values=outputChanges_.getParameterData(q);ParamValue value=0;int32 offset=0;if(values->getPoint(values->getPointCount()-1,offset,value)!=kResultOk||!std::isfinite(value))continue;for(int32 i=0;i<parameterCount_;++i)if(parameters_[i].id==values->getParameterId()){parameters_[i].output.store(value);parameters_[i].outputDirty.store(true,std::memory_order_release);break;}}
            error_=result;
        }
        sampleTime_+=frames;
        for(uint32_t f=0;f<frames;++f){mix_+=std::clamp(target_-mix_,-1.f/240,1.f/240);for(uint32_t c=0;c<2;++c){uint32_t wetChannel=std::min(c,uint32_t(outputChannels_-1));float wet=result==kResultOk&&!(outputs_[0].silenceFlags&(uint64(1)<<wetChannel))?outputPointers_[wetChannel][f]:0;if(!std::isfinite(wet))wet=0;audio[c][f]=buffers_[(4+c)*Capacity+f]*(1-mix_)+wet*mix_;}}
        rendering_.fetch_sub(1,std::memory_order_seq_cst);
    }
    void reset()noexcept override{}
    void resetStopped()override{sampleTime_=0;restart_.fetch_or(kLatencyChanged);service();}
    void setBypassed(bool value)noexcept override{target_=value?0:1;}
    tresult edit(ParamID id,ParamValue value){if(!std::isfinite(value))return kInvalidArgument;for(int32 i=0;i<parameterCount_;++i)if(parameters_[i].id==id){parameters_[i].input.store(std::clamp(value,0.,1.));parameters_[i].inputDirty.store(true,std::memory_order_release);return kResultOk;}return kInvalidArgument;}
    void restart(int32 flags){restart_.fetch_or(flags);}
    void service()override{
        mainThread([&]{try {
            if(!processor_||needsReload_)return;
            int32 flags=restart_.exchange(0);
            if(flags&kParamValuesChanged)syncParameters();
            // Reconfiguration is done between callbacks: IO observes suspension
            // and emits silence without waiting for the control thread.
            if(flags&(kLatencyChanged|kIoChanged|kReloadComponent))suspended_.store(true,std::memory_order_seq_cst);
            if(suspended_.load()&&rendering_.load(std::memory_order_seq_cst)==0){
                if(processing_){processor_->setProcessing(false);processing_=false;}
                if(active_){component_->setActive(false);active_=false;}
                if(flags&(kIoChanged|kReloadComponent)){needsReload_=true;failure=@"Plugin configuration changed. Reload this insert to apply its new configuration.";return;}
                check(component_->setActive(true),"VST3 latency reactivation");active_=true;
                auto result=processor_->setProcessing(true);if(result!=kResultOk&&result!=kNotImplemented)check(result,"VST3 processing restart");processing_=true;
                latency_=processor_->getLatencySamples();error_=0;suspended_=false;
            } else if(suspended_.load())restart_.fetch_or(flags);
            if(controller_)for(int32 i=0;i<parameterCount_;++i)if(parameters_[i].outputDirty.exchange(false,std::memory_order_acquire)&&!parameters_[i].inputDirty.load())controller_->setParamNormalized(parameters_[i].id,parameters_[i].output.load());
        } catch(const std::exception& e) {failure=string(e.what());needsReload_=true;suspended_=true;} });
    }
    NSData* data()const override{
        NSData* result=nil;
        mainThread([&]{
            if(!component_)return;
            // Snapshot pending edits before asking the component for its state.
            // Re-sending every parameter (especially program selectors) after
            // setState can load a preset again and overwrite the restored state.
            NSMutableArray* values=[NSMutableArray array];
            for(int32 i=0;i<parameterCount_;++i)if(parameters_[i].inputDirty.load(std::memory_order_acquire)&&!(parameters_[i].flags&ParameterInfo::kIsReadOnly)){
                double v=parameters_[i].input.load();if(std::isfinite(v))[values addObject:@{@"id":@(parameters_[i].id),@"value":@(std::clamp(v,0.,1.))}];
            }
            Stream component;if(component_->getState(&component)!=kResultOk||component.failed)return;
            NSMutableDictionary* state=[@{@"version":@1,@"classID":identifier_,@"component":[NSData dataWithBytes:component.bytes.data() length:component.bytes.size()]} mutableCopy];
            if(controller_){Stream control;if(controller_->getState(&control)==kResultOk&&!control.failed&&control.bytes.size())state[@"controller"]=[NSData dataWithBytes:control.bytes.data() length:control.bytes.size()];}
            state[@"parameters"]=values;
            NSData* bytes=[NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];if(bytes.length<=StateLimit)result=bytes;
        });return result;
    }
    std::vector<uint8_t> saveState()const override{NSData* d=data();if(!d)return {};auto p=static_cast<const uint8_t*>(d.bytes);return {p,p+d.length};}
    void restoreState(const std::vector<uint8_t>& bytes)override{mainThread([&]{if(active_)throw std::runtime_error("Restore VST3 state by replacing the prepared insert");restoreData([NSData dataWithBytes:bytes.data() length:bytes.size()]);});}
    IEditController* controller()const{return controller_;}
    NSView* makeView()override;
};
tresult Handler::performEdit(ParamID id,ParamValue value){return owner?owner->edit(id,value):kResultFalse;}
tresult Handler::restartComponent(int32 flags){if(owner)owner->restart(flags);return kResultOk;}
}

// Use host-owned parameter controls. Vendor VST3 Cocoa windows are not enabled:
// installed plugins failed asynchronous editor teardown in the native checks.
@interface MDVST3ParameterView : NSView
- (instancetype)initWithProcessor:(VST3Processor*)processor;
@end
@implementation MDVST3ParameterView {
    VST3Processor* _processor;
    NSMutableArray<NSSlider*>* _sliders;
    NSMutableArray<NSTextField*>* _labels;
    NSTimer* _timer;
}
- (instancetype)initWithProcessor:(VST3Processor*)processor {
    auto controller=processor->controller();int32 count=controller?controller->getParameterCount():0;
    if((self=[super initWithFrame:NSMakeRect(0,0,620,std::max(100,40*count))])){
        _processor=processor;_sliders=[NSMutableArray array];_labels=[NSMutableArray array];
        for(int32 i=0;i<count;++i){ParameterInfo info{};if(controller->getParameterInfo(i,info)!=kResultOk||(info.flags&ParameterInfo::kIsHidden))continue;
            auto label=[NSTextField labelWithString:string16(info.title)];label.frame=NSMakeRect(12,40*_sliders.count+8,235,24);[self addSubview:label];
            auto slider=[NSSlider sliderWithValue:controller->getParamNormalized(info.id) minValue:0 maxValue:1 target:self action:@selector(change:)];slider.frame=NSMakeRect(255,40*_sliders.count+8,210,24);slider.tag=info.id;slider.enabled=!(info.flags&ParameterInfo::kIsReadOnly);if(info.stepCount>0&&info.stepCount<100){slider.numberOfTickMarks=info.stepCount+1;slider.allowsTickMarkValuesOnly=true;}[self addSubview:slider];[_sliders addObject:slider];
            auto value=[NSTextField labelWithString:@""];value.frame=NSMakeRect(478,40*(_sliders.count-1)+8,130,24);[self addSubview:value];[_labels addObject:value];
        }
        [self setFrameSize:NSMakeSize(620,std::max<NSUInteger>(100,40*_sliders.count))];
        if(!count){auto label=[NSTextField labelWithString:@"This effect does not expose editable parameters."];label.frame=NSMakeRect(20,35,580,25);[self addSubview:label];}
        __weak MDVST3ParameterView* weak=self;_timer=[NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer*){[weak refresh];}];[self refresh];
    }return self;
}
- (BOOL)isFlipped{return YES;}
- (void)change:(NSSlider*)slider {auto c=_processor->controller();c->setParamNormalized(ParamID(slider.tag),slider.doubleValue);_processor->edit(ParamID(slider.tag),slider.doubleValue);[self refresh];}
- (void)refresh {auto c=_processor->controller();for(NSUInteger i=0;i<_sliders.count;++i){auto slider=_sliders[i];auto value=c->getParamNormalized(ParamID(slider.tag));slider.doubleValue=value;String128 text{};_labels[i].stringValue=c->getParamStringByValue(ParamID(slider.tag),value,text)==kResultOk?string16(text):[NSString stringWithFormat:@"%.3f",value];}}
- (void)dealloc{[_timer invalidate];}
@end
namespace {
NSView* VST3Processor::makeView(){return [[MDVST3ParameterView alloc] initWithProcessor:this];}
}
NSArray* desk::vst3Catalog(){return scan();}
std::shared_ptr<desk::HostedProcessor> desk::makeVST3(NSString* identifier,NSData* state,bool mono){if(!scanned)scan();return std::make_shared<VST3Processor>(identifier,state,mono);}

bool desk::runVST3ScanCommand(){
    NSArray<NSString*>* args=NSProcessInfo.processInfo.arguments;
    if(args.count!=4||![args[1] isEqual:@"--desk-scan-vst3"])return false;
    // Executed before SwiftUI/DeskStore initialization in a fresh process.
    // Exiting directly avoids vendor static teardown after metadata capture.
    @autoreleasepool {
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSArray* items=@[];
        try {items=inspectBundle(args[2]);}catch(const std::exception&){}
        NSData* bytes=[NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
        bool saved=bytes&&[bytes writeToFile:args[3] atomically:YES];
        _exit(saved?0:1);
    }
}
