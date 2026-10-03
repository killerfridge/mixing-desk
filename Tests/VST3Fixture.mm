// Minimal independent VST3 effect used to exercise the actual bundle ABI.
// No audio hardware, plugin installation or vendor license is required.
#import <AppKit/AppKit.h>
#include "../Sources/DeskAudio/VST3Support.hpp"
#include <cassert>
using namespace desk::vst3;
static FUID effectID(0x10203040,0x50607080,0x90A0B0C0,0xD0E0F001);
static FUID monoID(0x10203040,0x50607080,0x90A0B0C0,0xD0E0F002);
static FUID instrumentID(0x10203040,0x50607080,0x90A0B0C0,0xD0E0F003);
static FUID controllerID(0x10203040,0x50607080,0x90A0B0C0,0xD0E0F004);
static std::shared_ptr<bool> pendingController;
static std::shared_ptr<double> pendingMode;
class Effect final:public IComponent,public IAudioProcessor,public IEditController {
    std::atomic<uint32> refs{1};
    std::atomic<double> gain{.5};double uiGain=.5,mode=0;
    IComponentHandler* handler=nullptr;
    bool monoOnly=false,initialized=false,active=false,processing=false;
    bool separate=false,controllerOnly=false;std::shared_ptr<bool> controllerAlive;std::shared_ptr<double> sharedMode=std::make_shared<double>(0);
    int channels=2;uint32 latency=7;
public:
    explicit Effect(bool mono,bool split=false,bool control=false):monoOnly(mono),separate(split),controllerOnly(control){
        if(split){controllerAlive=std::make_shared<bool>(false);pendingController=controllerAlive;pendingMode=sharedMode;}
        if(control){controllerAlive=pendingController;sharedMode=pendingMode;assert(controllerAlive);*controllerAlive=true;}
    }
    ~Effect(){if(controllerOnly)*controllerAlive=false;}
    uint32 PLUGIN_API addRef()override{return ++refs;}
    uint32 PLUGIN_API release()override{auto n=--refs;if(!n)delete this;return n;}
    tresult PLUGIN_API queryInterface(const TUID id,void** out)override{
        *out=nullptr;
        if(FUnknownPrivate::iidEqual(id,FUnknown::iid)||FUnknownPrivate::iidEqual(id,IComponent::iid)||FUnknownPrivate::iidEqual(id,IPluginBase::iid))*out=static_cast<IComponent*>(this);
        if(FUnknownPrivate::iidEqual(id,IAudioProcessor::iid))*out=static_cast<IAudioProcessor*>(this);
        if(!separate&&FUnknownPrivate::iidEqual(id,IEditController::iid))*out=static_cast<IEditController*>(this);
        if(!*out)return kNoInterface;addRef();return kResultOk;
    }
    tresult PLUGIN_API initialize(FUnknown* context)override{assert(NSThread.isMainThread&&!initialized);auto host=query<IHostApplication>(context);assert(host);String128 name{};assert(host->getName(name)==kResultOk);auto message=allocateMessage(host);assert(message);message->setMessageID("fixture");message->getAttributes()->setInt("number",42);int64 n=0;assert(message->getAttributes()->getInt("number",n)==kResultOk&&n==42);message->release();host->release();initialized=true;return kResultOk;}
    tresult PLUGIN_API terminate()override{assert(NSThread.isMainThread&&!active&&!processing);if(separate)assert(*controllerAlive);initialized=false;return kResultOk;}
    tresult PLUGIN_API getControllerClassId(TUID id)override{assert(!initialized);if(!separate)return kResultFalse;controllerID.toTUID(id);return kResultOk;}
    tresult PLUGIN_API setIoMode(IoMode)override{assert(!initialized);return kResultOk;}
    int32 PLUGIN_API getBusCount(MediaType type,BusDirection)override{return type==kAudio?1:0;}
    tresult PLUGIN_API getBusInfo(MediaType type,BusDirection direction,int32 index,BusInfo& info)override{if(type!=kAudio||index)return kInvalidArgument;info={};info.mediaType=kAudio;info.direction=direction;info.channelCount=channels;info.busType=kMain;return kResultOk;}
    tresult PLUGIN_API getRoutingInfo(RoutingInfo&,RoutingInfo&)override{return kNotImplemented;}
    tresult PLUGIN_API activateBus(MediaType,BusDirection,int32,TBool)override{return kResultOk;}
    tresult PLUGIN_API setActive(TBool on)override{assert(NSThread.isMainThread);active=on;if(on)latency=*sharedMode>.5?19:7;return kResultOk;}
    tresult PLUGIN_API setState(IBStream* stream)override{char block[4096]{};int32 n=0;if(stream->read(block,sizeof(block),&n)!=kResultOk||n!=sizeof(double))return kResultFalse;double v;memcpy(&v,block,sizeof(v));gain=v;uiGain=v;return kResultOk;}
    tresult PLUGIN_API getState(IBStream* stream)override{double v=controllerOnly?uiGain:gain.load();return stream->write(&v,sizeof(v),nullptr);}
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* in,int32 ins,SpeakerArrangement* out,int32 outs)override{if(ins!=1||outs!=1||in[0]!=out[0]||(in[0]!=SpeakerArr::kStereo&&in[0]!=SpeakerArr::kMono)||(monoOnly&&in[0]!=SpeakerArr::kMono))return kResultFalse;channels=in[0]==SpeakerArr::kMono?1:2;return kResultOk;}
    tresult PLUGIN_API getBusArrangement(BusDirection,int32,SpeakerArrangement& layout)override{layout=channels==1?SpeakerArr::kMono:SpeakerArr::kStereo;return kResultOk;}
    tresult PLUGIN_API canProcessSampleSize(int32 size)override{return size==kSample32?kResultOk:kResultFalse;}
    uint32 PLUGIN_API getLatencySamples()override{return latency;}
    tresult PLUGIN_API setupProcessing(ProcessSetup& setup)override{assert(NSThread.isMainThread);return setup.sampleRate==48000&&setup.symbolicSampleSize==kSample32&&setup.maxSamplesPerBlock<=4096?kResultOk:kResultFalse;}
    tresult PLUGIN_API setProcessing(TBool on)override{processing=on;return kResultOk;}
    tresult PLUGIN_API process(ProcessData& data)override{
        assert(active&&processing&&data.numInputs==1&&data.numOutputs==1&&data.processContext&&data.processContext->sampleRate==48000);
        for(int32 i=0;i<data.inputParameterChanges->getParameterCount();++i){auto q=data.inputParameterChanges->getParameterData(i);int32 offset;ParamValue value;q->getPoint(0,offset,value);if(q->getParameterId()==0)gain=value;}
        for(int c=0;c<channels;++c)for(int f=0;f<data.numSamples;++f)data.outputs[0].channelBuffers32[c][f]=data.inputs[0].channelBuffers32[c][f]*gain.load();
        int32 index;auto q=data.outputParameterChanges->addParameterData(2,index);if(q)q->addPoint(data.numSamples-1,.75,index);
        return kResultOk;
    }
    uint32 PLUGIN_API getTailSamples()override{return 0;}
    tresult PLUGIN_API setComponentState(IBStream* stream)override{return setState(stream);}
    int32 PLUGIN_API getParameterCount()override{return 3;}
    tresult PLUGIN_API getParameterInfo(int32 index,ParameterInfo& info)override{if(index<0||index>2)return kInvalidArgument;info={};info.id=index;info.defaultNormalizedValue=.5;info.flags=index==2?ParameterInfo::kIsReadOnly:ParameterInfo::kCanAutomate;std::u16string title=index==0?u"Gain":index==1?u"Latency mode":u"Meter";std::copy(title.begin(),title.end(),info.title);return kResultOk;}
    tresult PLUGIN_API getParamStringByValue(ParamID,ParamValue value,String128 text)override{std::u16string s=value<.5?u"Low":u"High";std::copy(s.begin(),s.end(),text);text[s.size()]=0;return kResultOk;}
    tresult PLUGIN_API getParamValueByString(ParamID,TChar*,ParamValue&)override{return kResultFalse;}
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID,ParamValue value)override{return value;}
    ParamValue PLUGIN_API plainParamToNormalized(ParamID,ParamValue value)override{return value;}
    ParamValue PLUGIN_API getParamNormalized(ParamID id)override{return id==0?uiGain:id==1?*sharedMode:.75;}
    tresult PLUGIN_API setParamNormalized(ParamID id,ParamValue value)override{if(id==0)uiGain=value;if(id==1){*sharedMode=value;if(handler)handler->restartComponent(kLatencyChanged);}return kResultOk;}
    tresult PLUGIN_API setComponentHandler(IComponentHandler* h)override{if(handler)handler->release();handler=h;if(handler)handler->addRef();return kResultOk;}
    IPlugView* PLUGIN_API createView(FIDString)override{return nullptr;}
};
class Factory final:public IPluginFactory2 {
public:
    uint32 PLUGIN_API addRef()override{return 1;}
    uint32 PLUGIN_API release()override{return 1;}
    tresult PLUGIN_API queryInterface(const TUID id,void** out)override{*out=nullptr;if(FUnknownPrivate::iidEqual(id,IPluginFactory2::iid)||FUnknownPrivate::iidEqual(id,IPluginFactory::iid)||FUnknownPrivate::iidEqual(id,FUnknown::iid)){*out=this;return kResultOk;}return kNoInterface;}
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info)override{*info={};strcpy(info->vendor,"Mixing Desk Tests");return kResultOk;}
    int32 PLUGIN_API countClasses()override{return 4;}
    tresult PLUGIN_API getClassInfo(int32 index,PClassInfo* info)override{if(index<0||index>3)return kInvalidArgument;*info={};(index==0?effectID:index==1?monoID:index==2?instrumentID:controllerID).toTUID(info->cid);strcpy(info->category,index==3?kVstComponentControllerClass:kVstAudioEffectClass);strcpy(info->name,index==0?"Test Gain":index==1?"Test Mono Gain":index==2?"Test Instrument":"Test Controller");return kResultOk;}
    tresult PLUGIN_API getClassInfo2(int32 index,PClassInfo2* info)override{PClassInfo basic{};if(getClassInfo(index,&basic)!=kResultOk)return kInvalidArgument;*info={};memcpy(info->cid,basic.cid,16);strcpy(info->category,basic.category);strcpy(info->name,basic.name);strcpy(info->vendor,"Mixing Desk Tests");strcpy(info->subCategories,index==2?"Instrument|Synth":"Fx|Dynamics");return kResultOk;}
    tresult PLUGIN_API createInstance(FIDString cid,FIDString iid,void** out)override{*out=nullptr;if(!FUnknownPrivate::iidEqual(cid,effectID)&&!FUnknownPrivate::iidEqual(cid,monoID)&&!FUnknownPrivate::iidEqual(cid,controllerID))return kInvalidArgument;auto effect=new Effect(FUnknownPrivate::iidEqual(cid,monoID),FUnknownPrivate::iidEqual(cid,effectID),FUnknownPrivate::iidEqual(cid,controllerID));auto result=effect->queryInterface(iid,out);effect->release();return result;}
};
extern "C" __attribute__((visibility("default"))) bool bundleEntry(CFBundleRef){return true;}
extern "C" __attribute__((visibility("default"))) bool bundleExit(){return true;}
extern "C" __attribute__((visibility("default"))) IPluginFactory* GetPluginFactory(){static Factory factory;return &factory;}
