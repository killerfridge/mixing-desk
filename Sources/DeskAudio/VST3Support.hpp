#pragma once
#include "VST3SDK/pluginterfaces/base/ibstream.h"
#include "VST3SDK/pluginterfaces/base/ipluginbase.h"
#include "VST3SDK/pluginterfaces/gui/iplugview.h"
#include "VST3SDK/pluginterfaces/vst/ivstaudioprocessor.h"
#include "VST3SDK/pluginterfaces/vst/ivsteditcontroller.h"
#include "VST3SDK/pluginterfaces/vst/ivsthostapplication.h"
#include "VST3SDK/pluginterfaces/vst/ivstparameterchanges.h"
#include "VST3SDK/pluginterfaces/vst/ivstprocesscontext.h"
#include "VST3SDK/pluginterfaces/vst/ivstevents.h"
#include <algorithm>
#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <variant>
#include <vector>

namespace desk::vst3 {
using namespace Steinberg;
using namespace Steinberg::Vst;
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<uint32>::is_always_lock_free);
constexpr size_t StateLimit=16*1024*1024;
template<class T> T* query(FUnknown* object) {
    T* result=nullptr;
    if(object)object->queryInterface(T::iid.toTUID(),reinterpret_cast<void**>(&result));
    return result;
}
template<class T> void release(T*& value) {if(value){value->release();value=nullptr;}}
// Embedded block queues and streams are borrowed for the duration of the call.
#define DESK_VST_BORROWED(Interface) \
    uint32 PLUGIN_API addRef() override {return 1;} \
    uint32 PLUGIN_API release() override {return 1;} \
    tresult PLUGIN_API queryInterface(const TUID id,void** out) override { \
        if(!out)return kInvalidArgument;*out=nullptr; \
        if(FUnknownPrivate::iidEqual(id,Interface::iid)||FUnknownPrivate::iidEqual(id,FUnknown::iid)){*out=static_cast<Interface*>(this);addRef();return kResultOk;}return kNoInterface;}

class Stream final: public IBStream {
    size_t cursor=0;
public:
    std::vector<uint8_t> bytes;
    bool failed=false;
    Stream()=default;
    Stream(const void* data,size_t size) {if(size>StateLimit){failed=true;return;}if(size)bytes.assign(static_cast<const uint8_t*>(data),static_cast<const uint8_t*>(data)+size);}
    DESK_VST_BORROWED(IBStream)
    tresult PLUGIN_API read(void* buffer,int32 count,int32* readCount) override {
        if(readCount)*readCount=0;
        if(count<0||(!buffer&&count))return kInvalidArgument;
        size_t n=std::min<size_t>(count,bytes.size()-std::min(cursor,bytes.size()));
        if(n)memcpy(buffer,bytes.data()+cursor,n);cursor+=n;if(readCount)*readCount=int32(n);
        // IBStream reports a successful short read at EOF through readCount.
        return kResultOk;
    }
    tresult PLUGIN_API write(void* buffer,int32 count,int32* written) override {
        if(written)*written=0;
        if(count<0||(!buffer&&count)||size_t(count)>StateLimit-cursor){failed=true;return kInvalidArgument;}
        bytes.resize(std::max(bytes.size(),cursor+count));if(count)memcpy(bytes.data()+cursor,buffer,count);cursor+=count;
        if(written)*written=count;return kResultOk;
    }
    tresult PLUGIN_API seek(int64 offset,int32 mode,int64* result) override {
        int64 base=mode==kIBSeekSet?0:mode==kIBSeekCur?int64(cursor):mode==kIBSeekEnd?int64(bytes.size()):-1;
        if(base<0||offset < -base||offset>int64(StateLimit)-base)return kInvalidArgument;
        cursor=size_t(base+offset);if(result)*result=cursor;return kResultOk;
    }
    tresult PLUGIN_API tell(int64* pos) override {if(!pos)return kInvalidArgument;*pos=cursor;return kResultOk;}
    void rewind(){cursor=0;}
};

class Attributes final:public IAttributeList {
    std::atomic<uint32> refs{1};
    using Value=std::variant<int64,double,std::u16string,std::vector<uint8_t>>;
    std::map<std::string,Value> values;
    template<class T> tresult get(AttrID id,T& value) {auto it=values.find(id?id:"");if(it==values.end())return kResultFalse;if(auto p=std::get_if<T>(&it->second)){value=*p;return kResultOk;}return kResultFalse;}
public:
    uint32 PLUGIN_API addRef()override{return ++refs;}
    uint32 PLUGIN_API release()override {auto n=--refs;if(!n)delete this;return n;}
    tresult PLUGIN_API queryInterface(const TUID id,void** out)override {if(!out)return kInvalidArgument;*out=nullptr;if(FUnknownPrivate::iidEqual(id,IAttributeList::iid)||FUnknownPrivate::iidEqual(id,FUnknown::iid)){*out=this;addRef();return kResultOk;}return kNoInterface;}
    tresult PLUGIN_API setInt(AttrID id,int64 v)override {if(!id)return kInvalidArgument;values[id]=v;return kResultOk;}
    tresult PLUGIN_API getInt(AttrID id,int64& v)override{return get(id,v);}
    tresult PLUGIN_API setFloat(AttrID id,double v)override {if(!id)return kInvalidArgument;values[id]=v;return kResultOk;}
    tresult PLUGIN_API getFloat(AttrID id,double& v)override{return get(id,v);}
    tresult PLUGIN_API setString(AttrID id,const TChar* v)override {if(!id||!v)return kInvalidArgument;values[id]=std::u16string(v);return kResultOk;}
    tresult PLUGIN_API getString(AttrID id,TChar* v,uint32 size)override {std::u16string s;if(!v||size<2)return kInvalidArgument;if(get(id,s)!=kResultOk)return kResultFalse;size_t n=std::min<size_t>(s.size(),size/2-1);memcpy(v,s.data(),n*2);v[n]=0;return kResultOk;}
    tresult PLUGIN_API setBinary(AttrID id,const void* data,uint32 size)override {if(!id||(!data&&size)||size>StateLimit)return kInvalidArgument;std::vector<uint8_t> v(size);if(size)memcpy(v.data(),data,size);values[id]=std::move(v);return kResultOk;}
    tresult PLUGIN_API getBinary(AttrID id,const void*& data,uint32& size)override {auto it=values.find(id?id:"");if(it==values.end())return kResultFalse;auto p=std::get_if<std::vector<uint8_t>>(&it->second);if(!p)return kResultFalse;data=p->data();size=uint32(p->size());return kResultOk;}
};
class Message final:public IMessage {
    std::atomic<uint32> refs{1};std::string id;Attributes* attributes=new Attributes;
    ~Message(){attributes->release();}
public:
    uint32 PLUGIN_API addRef()override{return ++refs;}
    uint32 PLUGIN_API release()override{auto n=--refs;if(!n)delete this;return n;}
    tresult PLUGIN_API queryInterface(const TUID iid,void** out)override {if(!out)return kInvalidArgument;*out=nullptr;if(FUnknownPrivate::iidEqual(iid,IMessage::iid)||FUnknownPrivate::iidEqual(iid,FUnknown::iid)){*out=this;addRef();return kResultOk;}return kNoInterface;}
    FIDString PLUGIN_API getMessageID()override{return id.c_str();}
    void PLUGIN_API setMessageID(FIDString s)override{id=s?s:"";}
    IAttributeList* PLUGIN_API getAttributes()override{return attributes;}
};
class Host:public IHostApplication {
public:
    DESK_VST_BORROWED(IHostApplication)
    tresult PLUGIN_API getName(String128 name)override {const char16_t value[]=u"Mixing Desk";std::fill_n(name,128,0);std::copy(std::begin(value),std::end(value),name);return kResultOk;}
    tresult PLUGIN_API createInstance(TUID cid,TUID iid,void** out)override {
        if(!out)return kInvalidArgument;*out=nullptr;
        if(FUnknownPrivate::iidEqual(cid,IMessage::iid)&&FUnknownPrivate::iidEqual(iid,IMessage::iid))*out=new Message;
        if(FUnknownPrivate::iidEqual(cid,IAttributeList::iid)&&FUnknownPrivate::iidEqual(iid,IAttributeList::iid))*out=new Attributes;
        return *out?kResultOk:kNoInterface;
    }
};
struct Parameter {
    ParamID id=0;int32 flags=0;
    // UI is the producer of input values; IO is the producer of output values.
    // Exchange on dirty makes the preceding value publication visible.
    std::atomic<double> input{0},output{0};
    std::atomic<bool> inputDirty{false},outputDirty{false};
};
class ValueQueue final:public IParamValueQueue {
public:
    ParamID id=0;ParamValue value=0;int32 offset=0;bool hasValue=false;
    DESK_VST_BORROWED(IParamValueQueue)
    ParamID PLUGIN_API getParameterId()override{return id;}
    int32 PLUGIN_API getPointCount()override{return hasValue?1:0;}
    tresult PLUGIN_API getPoint(int32 index,int32& at,ParamValue& v)override {if(index!=0||!hasValue)return kInvalidArgument;at=offset;v=value;return kResultOk;}
    // The host applies UI changes at block boundaries and retains the last
    // output point for controller feedback. Neither path allocates in IO.
    tresult PLUGIN_API addPoint(int32 at,ParamValue v,int32& index)override {offset=at;value=v;hasValue=true;index=0;return kResultOk;}
};
class Changes final:public IParameterChanges {
    std::unique_ptr<ValueQueue[]> queues;int32 capacity=0,count=0;
public:
    DESK_VST_BORROWED(IParameterChanges)
    void prepare(int32 n){capacity=n;queues=std::make_unique<ValueQueue[]>(n);}
    void clear(){count=0;}
    int32 PLUGIN_API getParameterCount()override{return count;}
    IParamValueQueue* PLUGIN_API getParameterData(int32 index)override{return index>=0&&index<count?&queues[index]:nullptr;}
    IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id,int32& index)override {
        for(int32 i=0;i<count;++i)if(queues[i].id==id){index=i;return &queues[i];}
        if(count>=capacity){index=-1;return nullptr;}index=count++;auto& q=queues[index];q.id=id;q.hasValue=false;return &q;
    }
};
class Events final:public IEventList {
public:
    DESK_VST_BORROWED(IEventList)
    int32 PLUGIN_API getEventCount()override{return 0;}
    tresult PLUGIN_API getEvent(int32,Event&)override{return kInvalidArgument;}
    tresult PLUGIN_API addEvent(Event&)override{return kResultFalse;}
};
}
