#pragma once
#include "InsertProcessor.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <complex>
#include <stdexcept>

namespace desk {
constexpr int MaxInserts = 4;
struct EQParameters {
    double lowFrequency=120, lowGain=0, midFrequency=1000, midGain=0;
    double midQ=1, highFrequency=8000, highGain=0, outputGain=0;
    bool operator==(const EQParameters&) const = default;
    bool valid() const noexcept {
        auto range=[](double x,double lo,double hi){return std::isfinite(x)&&x>=lo&&x<=hi;};
        return range(lowFrequency,20,20000)&&range(midFrequency,20,20000)&&range(highFrequency,20,20000)
            &&range(lowGain,-18,18)&&range(midGain,-18,18)&&range(highGain,-18,18)
            &&range(midQ,.1,10)&&range(outputGain,-18,18);
    }
};
struct BiquadCoefficients {
    double b0=1,b1=0,b2=0,a1=0,a2=0;
    bool operator==(const BiquadCoefficients&) const = default;
};
struct PreparedEQ {
    std::array<BiquadCoefficients,3> bands{};
    double output=1;
    bool operator==(const PreparedEQ&) const = default;
};
// RBJ/W3C Audio EQ Cookbook: low/high shelves use slope S=1.
// Coefficients are calculated on the control thread, never during rendering.
inline PreparedEQ prepareEQ(const EQParameters& p,double rate=48000) {
    if(!p.valid() || !std::isfinite(rate) || rate<=40000)throw std::invalid_argument("Invalid EQ parameters or sample rate");
    PreparedEQ result;
    const double frequencies[]={p.lowFrequency,p.midFrequency,p.highFrequency};
    const double gains[]={p.lowGain,p.midGain,p.highGain};
    for(int i=0;i<3;++i) {
        if(gains[i]==0)continue; // Exact unity at the default settings.
        double w=2*3.14159265358979323846*frequencies[i]/rate,c=std::cos(w),s=std::sin(w),A=std::pow(10.,gains[i]/40.);
        double b0,b1,b2,a0,a1,a2;
        if(i==1) {
            double alpha=s/(2*p.midQ);
            b0=1+alpha*A;b1=-2*c;b2=1-alpha*A;a0=1+alpha/A;a1=-2*c;a2=1-alpha/A;
        } else {
            double t=s*std::sqrt(2*A);
            if(i==0) {
                b0=A*((A+1)-(A-1)*c+t);b1=2*A*((A-1)-(A+1)*c);b2=A*((A+1)-(A-1)*c-t);
                a0=(A+1)+(A-1)*c+t;a1=-2*((A-1)+(A+1)*c);a2=(A+1)+(A-1)*c-t;
            } else {
                b0=A*((A+1)+(A-1)*c+t);b1=-2*A*((A-1)+(A+1)*c);b2=A*((A+1)+(A-1)*c-t);
                a0=(A+1)-(A-1)*c+t;a1=2*((A-1)-(A+1)*c);a2=(A+1)-(A-1)*c-t;
            }
        }
        result.bands[i]={b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
    }
    result.output=std::pow(10.,p.outputGain/20.);return result;
}
inline double eqResponseDB(const PreparedEQ& eq,double frequency,double rate=48000) {
    auto z=std::polar(1.,-2*3.14159265358979323846*frequency/rate);
    double magnitude=eq.output;
    for(const auto& b:eq.bands)magnitude*=std::abs((b.b0+b.b1*z+b.b2*z*z)/(1.+b.a1*z+b.a2*z*z));
    return 20*std::log10(std::max(1e-12,magnitude));
}
class Equalizer final : public InsertProcessor {
    struct Bank {
        PreparedEQ coefficients;
        double z1[3][2]{},z2[3][2]{};
        double sample(double x,int channel) noexcept {
            for(int i=0;i<3;++i) {
                const auto& b=coefficients.bands[i];
                double y=b.b0*x+z1[i][channel];
                z1[i][channel]=b.b1*x-b.a1*y+z2[i][channel];z2[i][channel]=b.b2*x-b.a2*y;
                if(std::abs(z1[i][channel])<1e-24)z1[i][channel]=0;
                if(std::abs(z2[i][channel])<1e-24)z2[i][channel]=0;
                x=y;
            }
            return x*coefficients.output;
        }
    };
    std::array<Bank,2> banks_{};
    PreparedEQ requested_{},wet_{};
    EQParameters parameters_{};
    double sampleRate_=48000;
    bool bypassed_=false;
    int current_=0,remaining_=0;
    static constexpr int FadeFrames=240;
public:
    void prepare(double rate,uint32_t,uint32_t channels) override {
        if(channels<1||channels>2)throw std::invalid_argument("EQ supports mono/stereo");
        wet_=prepareEQ(parameters_,rate);sampleRate_=rate;requested_=bypassed_?PreparedEQ{}:wet_;reset();
    }
    // Called by the render thread with an already-prepared mailbox snapshot.
    void configure(const PreparedEQ& coefficients,const EQParameters& p,bool bypassed) noexcept {
        wet_=coefficients;parameters_=p;setBypassed(bypassed);
    }
    void setBypassed(bool value) noexcept override {bypassed_=value;requested_=value?PreparedEQ{}:wet_;}
    void reset() noexcept override {banks_={};current_=0;remaining_=0;}
    void process(float* const* audio,uint32_t channels,uint32_t frames) noexcept override {
        if(channels<1||channels>2)return;
        if(!remaining_ && banks_[current_].coefficients==PreparedEQ{} && requested_==PreparedEQ{})return;
        for(uint32_t f=0;f<frames;++f) {
            if(!remaining_ && !(banks_[current_].coefficients==requested_)) {
                banks_[1-current_]={};banks_[1-current_].coefficients=requested_;remaining_=FadeFrames;
            }
            double blend=remaining_?double(FadeFrames-remaining_+1)/FadeFrames:0;
            for(uint32_t c=0;c<channels;++c) {
                double x=std::isfinite(audio[c][f])?audio[c][f]:0;
                double y=banks_[current_].sample(x,c);
                if(remaining_)y+=(banks_[1-current_].sample(x,c)-y)*blend;
                audio[c][f]=std::isfinite(y)?float(y):0;
            }
            if(remaining_ && !--remaining_)current_=1-current_;
        }
    }
    uint32_t latencyFrames() const noexcept override {return 0;}
    // Versioned, little-endian binary state for the processor interface. Sessions
    // use versioned JSON EQ settings; neither format is used in audio callbacks.
    std::vector<uint8_t> saveState() const override {
        std::vector<uint8_t> bytes{1,uint8_t(bypassed_)};
        for(double d:{parameters_.lowFrequency,parameters_.lowGain,parameters_.midFrequency,parameters_.midGain,parameters_.midQ,parameters_.highFrequency,parameters_.highGain,parameters_.outputGain}) {
            auto bits=std::bit_cast<uint64_t>(d);for(int i=0;i<8;++i)bytes.push_back(uint8_t(bits>>(8*i)));
        }return bytes;
    }
    void restoreState(const std::vector<uint8_t>& bytes) override {
        if(bytes.size()!=66||bytes[0]!=1||bytes[1]>1)throw std::invalid_argument("Invalid EQ state");
        std::array<double,8> values{};
        for(int j=0;j<8;++j){uint64_t bits=0;for(int i=0;i<8;++i)bits|=uint64_t(bytes[2+j*8+i])<<(8*i);values[j]=std::bit_cast<double>(bits);}
        EQParameters p{values[0],values[1],values[2],values[3],values[4],values[5],values[6],values[7]};
        auto prepared=prepareEQ(p,sampleRate_);configure(prepared,p,bytes[1]);reset();
    }
};
struct InsertConfiguration {
    uint64_t identity=0;
    bool bypassed=false;
    EQParameters parameters;
    PreparedEQ prepared;
    // Lifetime is retained by the control-thread rack until render acknowledges
    // a newer configuration. No shared_ptr traffic or destruction in IO.
    InsertProcessor* external=nullptr;
};
struct InsertChain {
    uint64_t origin=0;
    int active=0;
    std::array<Equalizer,MaxInserts> effects;
    std::array<uint64_t,MaxInserts> identities{};
    std::array<InsertProcessor*,MaxInserts> external{};
    void reset() noexcept {for(auto& effect:effects)effect.reset();identities={};external={};origin=0;active=0;}
    void configure(const std::array<InsertConfiguration,MaxInserts>& inserts,int count,uint64_t source) noexcept {
        if(source!=origin){reset();origin=source;}
        for(int i=0;i<count;++i) {
            if(identities[i]!=inserts[i].identity){effects[i].reset();identities[i]=inserts[i].identity;}
            effects[i].configure(inserts[i].prepared,inserts[i].parameters,inserts[i].bypassed);
            external[i]=inserts[i].external;
            if(external[i])external[i]->setBypassed(inserts[i].bypassed);
        }
        // Keep removed slots running dry so their transition to bypass is smooth.
        for(int i=count;i<active;++i){effects[i].setBypassed(true);external[i]=nullptr;}
        active=std::max(active,count);
    }
    void process(float* l,float* r,int frames) noexcept {
        float* audio[]={l,r};for(int i=0;i<active;++i) {
            if(external[i])external[i]->process(audio,2,frames);
            else effects[i].process(audio,2,frames);
        }
    }
};
}
