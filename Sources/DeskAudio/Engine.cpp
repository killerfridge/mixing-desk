#include "Engine.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace desk {
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<int>::is_always_lock_free);
float dbGain(float db) noexcept { return db <= -90 ? 0 : std::pow(10.f, db / 20.f); }
bool Configuration::validate(std::string& error) {
    auto fail = [&](const char* message) { error = message; return false; };
    if (stripCount < 0 || stripCount > MaxStrips || busCount < 0 || busCount > MaxBuses || routeCount < 0 || routeCount > MaxRoutes)
        return fail("Mixer capacity exceeded");
    auto channel = [](int c) { return c >= -1 && c < MaxChannels; };
    auto gain = [](float g) { return std::isfinite(g) && g >= 0 && g <= 64; };
    std::array<int, MaxBuses> degree{};
    auto prepareInserts=[](auto& owner) {
        if(owner.insertCount<0 || owner.insertCount>MaxInserts)return false;
        for(int i=0;i<owner.insertCount;++i) {
            auto& insert=owner.inserts[i];
            if(!insert.identity || !insert.parameters.valid())return false;
            for(int j=0;j<i;++j)if(owner.inserts[j].identity==insert.identity)return false;
            insert.prepared=prepareEQ(insert.parameters);
        }return true;
    };
    for (int i = 0; i < stripCount; ++i) {
        const auto& s = strips[i];
        if(!prepareInserts(strips[i]))return fail("Invalid channel inserts");
        if (!channel(s.left) || !channel(s.right) || !gain(s.trim) || !gain(s.fader) || !std::isfinite(s.pan) || std::abs(s.pan) > 1 || s.sendCount < 0 || s.sendCount > MaxSends)
            return fail("Invalid channel strip");
        for (int j = 0; j < s.sendCount; ++j)
            if (s.sends[j].bus < 0 || s.sends[j].bus >= busCount || !gain(s.sends[j].gain)) return fail("Invalid strip send");
    }
    for (int i = 0; i < busCount; ++i) {
        const auto& b = buses[i];
        if(!prepareInserts(buses[i]))return fail("Invalid bus inserts");
        buses[i].externalInserts=false;
        for(int j=0;j<b.insertCount;++j)buses[i].externalInserts |= b.inserts[j].external!=nullptr;
        if(buses[i].externalInserts && b.sendCount)return fail("Plugins require an output bus with no sends to other buses. Put the plugin on a channel or remove this bus's sends first.");
        if (!gain(b.gain) || b.sendCount < 0 || b.sendCount > MaxSends) return fail("Invalid bus");
        for (int j = 0; j < b.sendCount; ++j) {
            int to = b.sends[j].bus;
            if (to < 0 || to >= busCount || !gain(b.sends[j].gain)) return fail("Invalid bus send");
            ++degree[to];
        }
    }
    int count = 0;
    for (int i = 0; i < busCount; ++i) if (!degree[i]) busOrder[count++] = i;
    for (int k = 0; k < count; ++k) {
        const auto& b = buses[busOrder[k]];
        for (int j = 0; j < b.sendCount; ++j) if (!--degree[b.sends[j].bus]) busOrder[count++] = b.sends[j].bus;
    }
    if (count != busCount) return fail("Routing would create a feedback cycle");
    for (int i = 0; i < routeCount; ++i) {
        const auto& r = routes[i];
        if (r.source < 0 || r.source >= (r.fromBus ? busCount : stripCount) || !channel(r.left) || !channel(r.right) || !gain(r.gain)) return fail("Invalid output route");
    }
    return true;
}
void Engine::Smooth::set(float next) noexcept {
    if (next == target) return;
    target = next; remaining = 240; step = (target - value) / remaining;
}
float Engine::Smooth::next() noexcept {
    if (remaining > 0) { value += step; if (!--remaining) value = target; }
    return value;
}
Engine::Engine() : scratch_(new float[(MaxBuses * 5 + MaxBuses * MaxSends + 8) * MaxFrames]{}), stripInserts_(new InsertChain[MaxStrips]),busInserts_(new InsertChain[MaxBuses*MaxStrips]),terminalInserts_(new InsertChain[MaxBuses]) {}
Engine::~Engine() = default;
void Engine::reset() noexcept {
    stripState_={};busState_={};routeState_={};
    for(int i=0;i<MaxStrips;++i)stripInserts_[i].reset();
    for(int i=0;i<MaxBuses*MaxStrips;++i)busInserts_[i].reset();
    for(int i=0;i<MaxBuses;++i)terminalInserts_[i].reset();
}
void Engine::activateStopped() noexcept {
    if(mailbox_.load(std::memory_order_acquire)&Dirty)renderSlot_=mailbox_.exchange(renderSlot_,std::memory_order_acq_rel)&3;
    completed_.store(configs_[renderSlot_].generation,std::memory_order_release);
}
bool Engine::publish(const Configuration& config, std::string& error) {
    auto& prepared=configs_[controlSlot_];prepared=config;
    if (!prepared.validate(error)) return false;
    prepared.generation=++published_;
    controlSlot_ = mailbox_.exchange(controlSlot_ | Dirty, std::memory_order_acq_rel) & 3;
    return true;
}
void Engine::MeterSlot::write(const float* l, const float* r, int n) noexcept {
    float pl = 0, pr = 0; double sl = 0, sr = 0;
    for (int i = 0; i < n; ++i) { pl = std::max(pl, std::abs(l[i])); pr = std::max(pr, std::abs(r[i])); sl += l[i]*l[i]; sr += r[i]*r[i]; }
    // UI polls slower than IO; preserve peaks with a ~300 ms decay.
    const float decay = std::exp(-float(n) / 14400.f);
    peakL.store(std::max(pl, peakL.load(std::memory_order_relaxed) * decay), std::memory_order_relaxed);
    peakR.store(std::max(pr, peakR.load(std::memory_order_relaxed) * decay), std::memory_order_relaxed);
    rmsL.store(std::sqrt(sl/n), std::memory_order_relaxed); rmsR.store(std::sqrt(sr/n), std::memory_order_relaxed);
    if (pl >= 1 || pr >= 1) clip.store(true, std::memory_order_relaxed);
}
Meter Engine::MeterSlot::read() const noexcept { return {peakL.load(), peakR.load(), rmsL.load(), rmsR.load(), clip.load()}; }
Meter Engine::stripMeter(int i) const noexcept { return i >= 0 && i < MaxStrips ? stripMeters_[i].read() : Meter{}; }
Meter Engine::busMeter(int i) const noexcept { return i >= 0 && i < MaxBuses ? busMeters_[i].read() : Meter{}; }
void Engine::clearClip() noexcept { for (auto& m : stripMeters_) m.clip = false; for (auto& m : busMeters_) m.clip = false; }
void Engine::render(const float* const* inputs, int inCount, float* const* outputs, int outCount, int n) noexcept {
    if (n <= 0 || n > MaxFrames || outCount > MaxChannels || inCount > MaxChannels) return;
    for (int c = 0; c < outCount; ++c) std::fill_n(outputs[c], n, 0.f);
    if (mailbox_.load(std::memory_order_acquire) & Dirty)
        renderSlot_ = mailbox_.exchange(renderSlot_, std::memory_order_acq_rel) & 3;
    const auto& cfg = configs_[renderSlot_];
    float* total = scratch_.get();
    float* lane = total + MaxBuses * 2 * MaxFrames;
    float* preL = lane + MaxBuses * 2 * MaxFrames;
    float* preR = preL + MaxFrames;
    float* postL = preR + MaxFrames;
    float* postR = postL + MaxFrames;
    float* rawL = postR + MaxFrames;
    float* rawR = rawL + MaxFrames;
    float* directL = rawR + MaxFrames;
    float* directR = directL + MaxFrames;
    float* busEnvelope = directR + MaxFrames;
    float* sendEnvelope = busEnvelope + MaxBuses * MaxFrames;
    for (int b=0; b<cfg.busCount*2; ++b) std::fill_n(total+b*MaxFrames,n,0.f);
    bool anySolo = false;
    for (int s = 0; s < cfg.stripCount; ++s) anySolo |= cfg.strips[s].solo;
    // Gain envelopes are per sample but shared by all origin lanes, not advanced per lane.
    for (int b = 0; b < cfg.busCount; ++b) {
        auto& state = busState_[b]; const auto& bus = cfg.buses[b];
        if (state.identity != bus.identity) { state = {}; state.identity = bus.identity; }
        if(state.external!=bus.externalInserts) {
            for(int s=0;s<MaxStrips;++s)busInserts_[b*MaxStrips+s].reset();
            terminalInserts_[b].reset();state.external=bus.externalInserts;
        }
        state.gain.set(bus.mute ? 0 : bus.gain);
        for (int f = 0; f < n; ++f) busEnvelope[b*MaxFrames+f]=state.gain.next();
        for (int j = 0; j < bus.sendCount; ++j) {
            state.sends[j].set(bus.sends[j].gain);
            for (int f=0; f<n; ++f) sendEnvelope[(b*MaxSends+j)*MaxFrames+f]=state.sends[j].next();
        }
    }
    for (int k=0;k<cfg.routeCount;++k) {
        auto& state=routeState_[k];const auto& route=cfg.routes[k];
        uint64_t id=route.identity ? route.identity : uint64_t(k+1);
        if(state.identity!=id){state={};state.identity=id;}
        state.gain.set(route.gain);
    }
    auto emit = [&](int index, const float* l, const float* rr) {
        const auto& r=cfg.routes[index];
        for(int f=0;f<n;++f){
            float gain=routeState_[index].gain.next();
            if(r.left>=0&&r.left<outCount)outputs[r.left][f]+=l[f]*gain;
            if(r.right>=0&&r.right<outCount)outputs[r.right][f]+=rr[f]*gain;
        }
    };
    for (int s = 0; s < cfg.stripCount; ++s) {
        const auto& strip = cfg.strips[s]; auto& state = stripState_[s];
        if (state.identity != strip.identity) { state = {}; state.identity = strip.identity; }
        state.trim.set(strip.trim * (strip.polarity ? -1 : 1)); state.fader.set(strip.fader); state.mute.set(strip.mute ? 0 : 1);
        const float theta = (strip.pan + 1) * float(M_PI) * .25f;
        state.left.set(strip.mono ? std::cos(theta) : std::min(1.f, 1.f-strip.pan));
        state.right.set(strip.mono ? std::sin(theta) : std::min(1.f, 1.f+strip.pan));
        const float* il = strip.left >= 0 && strip.left < inCount ? inputs[strip.left] : nullptr;
        const float* ir = strip.right >= 0 && strip.right < inCount ? inputs[strip.right] : nullptr;
        uint64_t origin=strip.identity^std::rotl(strip.sourceIdentity,17)^uint64_t(strip.left+1)*65537^uint64_t(strip.right+1)*31337;
        stripInserts_[s].configure(strip.inserts,strip.insertCount,origin);
        for (int f = 0; f < n; ++f) {
            float trim = state.trim.next();
            float l = il && std::isfinite(il[f]) ? il[f]*trim : 0;
            float r = strip.mono ? l : (ir && std::isfinite(ir[f]) ? ir[f]*trim : 0);
            rawL[f] = l; rawR[f] = r;
        }
        stripInserts_[s].process(rawL,rawR,n);
        // Some analog-modelled units generate noise or keep long tails. A lost
        // source must still be silent, even with an active third-party insert.
        if(!il && (strip.mono || !ir)) {std::fill_n(rawL,n,0.f);std::fill_n(rawR,n,0.f);}
        for (int f = 0; f < n; ++f) {
            float mute=state.mute.next(),fg=state.fader.next();
            float l=rawL[f]*mute,r=rawR[f]*mute;rawL[f]=l;rawR[f]=r;
            directL[f] = l*fg; directR[f] = r*fg;
            preL[f] = l*state.left.next(); preR[f] = r*state.right.next();
            postL[f] = preL[f]*fg; postR[f] = preR[f]*fg;
        }
        stripMeters_[s].write(postL, postR, n);
        // Direct outputs are post trim/inserts/mute and optionally post fader, before pan.
        for (int k=0; k<cfg.routeCount; ++k) {
            const auto& route=cfg.routes[k];
            if (!route.fromBus && route.source==s) {
                if (route.pre) emit(k, rawL, rawR);
                else emit(k, directL, directR);
            }
        }
        for(int b=0;b<cfg.busCount*2;++b)std::fill_n(lane+b*MaxFrames,n,0.f);
        auto excluded = [&](int b) { const auto& bus = cfg.buses[b]; return bus.excludedSource && bus.excludedSource == strip.sourceIdentity; };
        for (int j=0; j<strip.sendCount; ++j) {
            const auto& send = strip.sends[j];
            state.sends[j].set(send.gain);
            float* l = lane + send.bus*2*MaxFrames; float* r=l+MaxFrames;
            for (int f=0; f<n; ++f) {
                float g=state.sends[j].next();
                if (!excluded(send.bus)) { l[f]+=(send.pre ? preL[f] : postL[f])*g; r[f]+=(send.pre ? preR[f] : postR[f])*g; }
            }
        }
        for (int order=0; order<cfg.busCount; ++order) {
            int b=cfg.busOrder[order]; const auto& bus=cfg.buses[b];
            float* l=lane+b*2*MaxFrames; float* r=l+MaxFrames;
            // EQ is linear: independent histories per source preserve transitive
            // mix-minus. Never let an excluded return's filter tail leak through.
            auto& inserts=busInserts_[b*MaxStrips+s];
            if (excluded(b) || (strip.mute && state.mute.value==0)) { if(inserts.active)inserts.reset();std::fill_n(l,n,0.f); std::fill_n(r,n,0.f); }
            else if(!bus.externalInserts) {
                inserts.configure(bus.inserts,bus.insertCount,origin^std::rotl(bus.identity,31));
                inserts.process(l,r,n);
            }
            for (int f=0; f<n; ++f) {
                float g=bus.externalInserts ? 1 : busEnvelope[b*MaxFrames+f];
                l[f]*=g; r[f]*=g;
                // Audition is applied only at the monitor output. A Monitor -> Call
                // patch must not propagate monitor solo/direct-guitar suppression.
                if (!(bus.monitor && ((anySolo && !strip.solo) || strip.directGuitar))) {
                    total[b*2*MaxFrames+f]+=l[f]; total[(b*2+1)*MaxFrames+f]+=r[f];
                }
            }
            for (int j=0; j<bus.sendCount; ++j) {
                const auto& send=bus.sends[j]; if (excluded(send.bus)) continue;
                float* dl=lane+send.bus*2*MaxFrames; float* dr=dl+MaxFrames;
                for (int f=0; f<n; ++f) { float gain=sendEnvelope[(b*MaxSends+j)*MaxFrames+f];dl[f]+=l[f]*gain;dr[f]+=r[f]*gain; }
            }
        }
    }
    for (int b=0; b<cfg.busCount; ++b) {
        float* l=total+b*2*MaxFrames;float* r=l+MaxFrames;const auto& bus=cfg.buses[b];
        if(bus.externalInserts) {
            // Nonlinear plugins must see the complete mix after exclusions and
            // monitor audition. Such buses cannot feed another bus: source
            // contributions cannot be separated after nonlinear processing.
            terminalInserts_[b].configure(bus.inserts,bus.insertCount,bus.identity^std::rotl(bus.excludedSource,13));
            terminalInserts_[b].process(l,r,n);
            for(int f=0;f<n;++f){l[f]*=busEnvelope[b*MaxFrames+f];r[f]*=busEnvelope[b*MaxFrames+f];}
        }
        busMeters_[b].write(l,r,n);
    }
    for (int k=0; k<cfg.routeCount; ++k) { const auto& r=cfg.routes[k]; if(r.fromBus) emit(k,total+r.source*2*MaxFrames,total+(r.source*2+1)*MaxFrames); }
    completed_.store(cfg.generation,std::memory_order_release);
}
}
