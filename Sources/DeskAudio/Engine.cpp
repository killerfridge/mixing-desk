#include "Engine.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace desk {
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<int>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);
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
    // Build connected components of destination channels on the control thread.
    // A stereo route links its pair; overlapping pairs link transitively. Mono
    // recording channels stay independent even when they share a device.
    std::array<int, MaxChannels> parent{}, groupForRoot{};
    std::array<bool, MaxChannels> used{};
    for (int c = 0; c < MaxChannels; ++c) { parent[c] = c; groupForRoot[c] = -1; }
    auto root = [&](int c) { while (parent[c] != c) c = parent[c]; return c; };
    auto mix = [](uint64_t h, uint64_t x) { return (h ^ x) * 1099511628211ULL; };
    uint64_t topology = mix(mix(mix(1469598103934665603ULL,stripCount),busCount),routeCount);
    for (int i = 0; i < stripCount; ++i) {
        const auto& s = strips[i];
        uint64_t h = mix(mix(mix(s.identity, s.sourceIdentity), s.left+1), s.right+1);
        h = mix(h, s.mono);
        for (int j = 0; j < s.sendCount; ++j) h ^= mix(buses[s.sends[j].bus].identity, s.sends[j].pre+1);
        topology ^= h;
    }
    for (int i = 0; i < busCount; ++i) {
        const auto& b = buses[i]; uint64_t h = mix(b.identity, b.excludedSource);
        for (int j = 0; j < b.sendCount; ++j) h ^= mix(buses[b.sends[j].bus].identity, 3);
        topology ^= h;
    }
    for (int i = 0; i < routeCount; ++i) {
        const auto& r = routes[i];
        if (r.left >= 0) used[r.left] = true;
        if (r.right >= 0) used[r.right] = true;
        if (r.left >= 0 && r.right >= 0) parent[root(r.right)] = root(r.left);
        uint64_t sourceID = r.fromBus ? buses[r.source].identity : strips[r.source].identity;
        auto dest = [&](int c) { return c < 0 ? uint64_t(0) : outputIdentities[c] ? outputIdentities[c] : uint64_t(c+1); };
        topology ^= mix(mix(mix(mix(r.identity, sourceID), r.fromBus*2+r.pre), dest(r.left)), dest(r.right));
    }
    protectionGroupCount = 0; nextProtectionChannel.fill(-1); protectionGroups = {};
    for (int c = MaxChannels-1; c >= 0; --c) if (used[c]) {
        int r = root(c), &g = groupForRoot[r];
        if (g < 0) g = protectionGroupCount++;
        nextProtectionChannel[c] = protectionGroups[g].firstChannel;
        protectionGroups[g].firstChannel = c;
        ++protectionGroups[g].channelCount;
    }
    for (int g = 0; g < protectionGroupCount; ++g) {
        auto& group = protectionGroups[g]; std::array<uint64_t, MaxChannels> identities{}; int count = 0;
        for (int c = group.firstChannel; c >= 0; c = nextProtectionChannel[c])
            identities[count++] = outputIdentities[c] ? outputIdentities[c] : uint64_t(c+1);
        std::sort(identities.begin(), identities.begin()+count);
        uint64_t h = 1469598103934665603ULL;
        for (int i = 0; i < count; ++i) h = mix(h, identities[i]);
        group.identity = h ? h : 1;
        group.historyIdentity = mix(group.identity, topology);
        // Delay storage uses aggregate offsets; moving a physical channel to a
        // different offset must flush it even when the linked identity is stable.
        for (int c=group.firstChannel; c>=0; c=nextProtectionChannel[c])
            group.historyIdentity=mix(group.historyIdentity,mix(uint64_t(c+1),outputIdentities[c]));
        // Solo changes only the monitor mix. Flush its final delayed audition.
        for (int i = 0; i < routeCount; ++i) if (routes[i].fromBus && buses[routes[i].source].monitor) {
            int c = routes[i].left >= 0 ? routes[i].left : routes[i].right;
            if (c >= 0 && groupForRoot[root(c)] == g)
                for (int j = 0; j < stripCount; ++j)
                    group.historyIdentity = mix(group.historyIdentity, strips[j].identity ^ (strips[j].solo ? 1 : 0) ^ (strips[j].directGuitar ? 2 : 0));
        }
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
Engine::Engine() : stripProtection_(new StripProtection[MaxStrips]), outputProtection_(new OutputProtection[MaxChannels]),
    outputDelay_(new float[MaxChannels * ProtectionLookahead]{}),
    scratch_(new float[(MaxBuses * 5 + MaxBuses * MaxSends + 8) * MaxFrames]{}),
    stripInserts_(new InsertChain[MaxStrips]),busInserts_(new InsertChain[MaxBuses*MaxStrips]),terminalInserts_(new InsertChain[MaxBuses]) {}
Engine::~Engine() = default;
void Engine::reset() noexcept {
    stripState_={};busState_={};routeState_={};
    auto quiet=[](auto& slots){for(auto& m:slots){m.peakL=0;m.peakR=0;m.rmsL=0;m.rmsR=0;m.reductionDB=0;}};
    quiet(stripMeters_);quiet(busMeters_);quiet(outputMeters_);
    for (int i=0; i<MaxStrips; ++i) { stripProtection_[i].origin=0; stripProtection_[i].pre.reset(true); stripProtection_[i].post.reset(true); }
    for (int i=0; i<MaxChannels; ++i) { outputProtection_[i].historyIdentity=0; outputProtection_[i].head=0; outputProtection_[i].envelope.reset(true); }
    std::fill_n(outputDelay_.get(), MaxChannels*ProtectionLookahead, 0.f);
    for(int i=0;i<MaxStrips;++i)stripInserts_[i].reset();
    for(int i=0;i<MaxBuses*MaxStrips;++i)busInserts_[i].reset();
    for(int i=0;i<MaxBuses;++i)terminalInserts_[i].reset();
}
void Engine::activateStopped() noexcept {
    if(mailbox_.load(std::memory_order_acquire)&Dirty)renderSlot_=mailbox_.exchange(renderSlot_,std::memory_order_acq_rel)&3;
    prepareMeters(configs_[renderSlot_]);serviceMeterResetsStopped();
    completed_.store(configs_[renderSlot_].generation,std::memory_order_release);
}
bool Engine::publish(const Configuration& config, std::string& error) {
    auto& prepared=configs_[controlSlot_];prepared=config;
    if (!prepared.validate(error)) return false;
    prepared.generation=++published_;
    controlSlot_ = mailbox_.exchange(controlSlot_ | Dirty, std::memory_order_acq_rel) & 3;
    return true;
}
void Engine::MeterSlot::clear() noexcept {
    peakL=0; peakR=0; rmsL=0; rmsR=0; heldL=0; heldR=0; reductionDB=0; clip=false;
}
void Engine::MeterSlot::begin(uint64_t epoch) noexcept {
    auto request = resetOwner.exchange(0, std::memory_order_relaxed);
    if (epoch != resetEpoch || (request && request == identity.load(std::memory_order_relaxed))) clear();
    resetEpoch = epoch;
}
void Engine::MeterSlot::writePeaks(float pl, float pr, double sl, double sr, int n, float minimumGain) noexcept {
    const float decay = std::exp(-float(n) / 14400.f);
    peakL.store(std::max(pl, peakL.load(std::memory_order_relaxed)*decay), std::memory_order_relaxed);
    peakR.store(std::max(pr, peakR.load(std::memory_order_relaxed)*decay), std::memory_order_relaxed);
    rmsL.store(std::sqrt(sl/n), std::memory_order_relaxed); rmsR.store(std::sqrt(sr/n), std::memory_order_relaxed);
    heldL.store(std::max(pl, heldL.load(std::memory_order_relaxed)), std::memory_order_relaxed);
    heldR.store(std::max(pr, heldR.load(std::memory_order_relaxed)), std::memory_order_relaxed);
    float reduction = -20*std::log10(std::max(1e-20f, minimumGain));
    reductionDB.store(std::max(reduction, reductionDB.load(std::memory_order_relaxed)*decay), std::memory_order_relaxed);
    if (pl >= 1 || pr >= 1) clip.store(true, std::memory_order_relaxed);
}
void Engine::MeterSlot::write(const float* l, const float* r, int n, float minimumGain) noexcept {
    float pl=0, pr=0; double sl=0, sr=0;
    for (int i=0; i<n; ++i) { pl=std::max(pl,std::abs(l[i])); pr=std::max(pr,std::abs(r[i])); sl+=double(l[i])*l[i]; sr+=double(r[i])*r[i]; }
    writePeaks(pl,pr,sl,sr,n,minimumGain);
}
Meter Engine::MeterSlot::read() const noexcept {
    return {peakL.load(),peakR.load(),rmsL.load(),rmsR.load(),clip.load(),heldL.load(),heldR.load(),reductionDB.load()};
}
void Engine::prepareMeters(const Configuration& cfg) noexcept {
    // Retain meter ownership across array reorderings; reclaim only deleted IDs.
    auto map = [](auto& slots, auto& mapping, int count, auto owner) {
        for (auto& slot : slots) {
            auto id=slot.identity.load(std::memory_order_relaxed); bool found=false;
            for (int i=0; i<count; ++i) found |= id && id==owner(i);
            if (!found) { slot.identity.store(0,std::memory_order_release); slot.clear(); }
        }
        for (int i=0; i<count; ++i) {
            uint64_t id=owner(i); int index=-1;
            for (int j=0; j<int(slots.size()); ++j) if (slots[j].identity.load(std::memory_order_relaxed)==id) { index=j; break; }
            if (index<0) for (int j=0; j<int(slots.size()); ++j) if (!slots[j].identity.load(std::memory_order_relaxed)) {
                index=j; slots[j].clear(); slots[j].identity.store(id,std::memory_order_release); break;
            }
            mapping[i]=index;
        }
    };
    map(stripMeters_,stripMeterSlots_,cfg.stripCount,[&](int i){return cfg.strips[i].identity ? cfg.strips[i].identity : uint64_t(i+1);});
    map(busMeters_,busMeterSlots_,cfg.busCount,[&](int i){return cfg.buses[i].identity ? cfg.buses[i].identity : uint64_t(i+1);});
    map(outputMeters_,outputMeterSlots_,cfg.protectionGroupCount,[&](int i){return cfg.protectionGroups[i].identity;});
    for (int i=0; i<MaxStrips; ++i) visibleStripIDs_[i].store(i<cfg.stripCount ? stripMeters_[stripMeterSlots_[i]].identity.load() : 0);
    for (int i=0; i<MaxBuses; ++i) visibleBusIDs_[i].store(i<cfg.busCount ? busMeters_[busMeterSlots_[i]].identity.load() : 0);
    meterGeneration_=cfg.generation;
}
Meter Engine::stripMeterForOwner(uint64_t id) const noexcept { for(const auto& m:stripMeters_)if(id && m.identity.load(std::memory_order_acquire)==id)return m.read();return {}; }
Meter Engine::busMeterForOwner(uint64_t id) const noexcept { for(const auto& m:busMeters_)if(id && m.identity.load(std::memory_order_acquire)==id)return m.read();return {}; }
Meter Engine::outputMeterForGroup(uint64_t id) const noexcept { for(const auto& m:outputMeters_)if(id && m.identity.load(std::memory_order_acquire)==id)return m.read();return {}; }
Meter Engine::stripMeter(int i) const noexcept { return i>=0 && i<MaxStrips ? stripMeterForOwner(visibleStripIDs_[i].load()) : Meter{}; }
Meter Engine::busMeter(int i) const noexcept { return i>=0 && i<MaxBuses ? busMeterForOwner(visibleBusIDs_[i].load()) : Meter{}; }
void Engine::resetMeter(uint64_t id, bool bus) noexcept {
    auto request=[&](auto& slots) { for(auto& m:slots)if(id && m.identity.load(std::memory_order_acquire)==id)m.resetOwner.store(id,std::memory_order_relaxed); };
    if(bus)request(busMeters_);else request(stripMeters_);
}
void Engine::resetAllMeters() noexcept { meterResetEpoch_.fetch_add(1,std::memory_order_relaxed); }
void Engine::serviceMeterResetsStopped() noexcept {
    auto epoch=meterResetEpoch_.load(std::memory_order_relaxed);
    for(auto& m:stripMeters_)m.begin(epoch);
    for(auto& m:busMeters_)m.begin(epoch);
    for(auto& m:outputMeters_)m.begin(epoch);
}
void Engine::render(const float* const* inputs, int inCount, float* const* outputs, int outCount, int n) noexcept {
    if (n <= 0 || n > MaxFrames || outCount > MaxChannels || inCount > MaxChannels) return;
    for (int c = 0; c < outCount; ++c) std::fill_n(outputs[c], n, 0.f);
    if (mailbox_.load(std::memory_order_acquire) & Dirty)
        renderSlot_ = mailbox_.exchange(renderSlot_, std::memory_order_acq_rel) & 3;
    const auto& cfg = configs_[renderSlot_];
    if (meterGeneration_ != cfg.generation) prepareMeters(cfg);
    uint64_t resetEpoch=meterResetEpoch_.load(std::memory_order_relaxed);
    for(auto& m:stripMeters_)m.begin(resetEpoch);
    for(auto& m:busMeters_)m.begin(resetEpoch);
    for(auto& m:outputMeters_)m.begin(resetEpoch);
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
        uint64_t origin=strip.identity^std::rotl(strip.sourceIdentity,17)^uint64_t(strip.left+1)*65537^uint64_t(strip.right+1)*31337^uint64_t(strip.mono);
        auto& protection=stripProtection_[s];
        if(protection.origin!=origin) { protection.origin=origin;protection.pre.reset(strip.limiterEnabled);protection.post.reset(strip.limiterEnabled); }
        protection.pre.enable(strip.limiterEnabled);protection.post.enable(strip.limiterEnabled);
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
        float minimumGain=1;
        for (int f = 0; f < n; ++f) {
            float mute=state.mute.next(),fg=state.fader.next();
            float l=rawL[f]*mute,r=rawR[f]*mute;
            float postLeft=l*fg,postRight=r*fg;
            float preGain=protection.pre.process(l,r);
            float postGain=protection.post.process(postLeft,postRight);
            minimumGain=std::min(minimumGain,std::min(preGain,postGain));
            rawL[f]=l;rawR[f]=r;directL[f]=postLeft;directR[f]=postRight;
            float panL=state.left.next(),panR=state.right.next();
            preL[f]=l*panL;preR[f]=r*panR;
            postL[f]=postLeft*panL;postR[f]=postRight*panR;
        }
        stripMeters_[stripMeterSlots_[s]].write(directL,directR,n,minimumGain);
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
        busMeters_[busMeterSlots_[b]].write(l,r,n);
    }
    for (int k=0; k<cfg.routeCount; ++k) { const auto& r=cfg.routes[k]; if(r.fromBus) emit(k,total+r.source*2*MaxFrames,total+(r.source*2+1)*MaxFrames); }
    // Final protection follows every contribution and route gain. Each physical
    // output has one delay; its linked group shares an anticipatory envelope.
    for (int g=0; g<cfg.protectionGroupCount; ++g) {
        const auto& group=cfg.protectionGroups[g];auto& state=outputProtection_[g];
        if(state.historyIdentity!=group.historyIdentity) {
            // Flush final history and ignore the old channel-lookahead samples
            // for 48 frames so a reassigned destination cannot inherit a pulse.
            state.historyIdentity=group.historyIdentity;state.head=0;state.discardUpstream=ProtectionLookahead;state.envelope.reset(cfg.outputProtectionEnabled);
            for(int c=group.firstChannel;c>=0;c=cfg.nextProtectionChannel[c])std::fill_n(outputDelay_.get()+c*ProtectionLookahead,ProtectionLookahead,0.f);
        }
        state.envelope.enable(cfg.outputProtectionEnabled);
        float minimumGain=1,peakL=0,peakR=0;double sumL=0,sumR=0;
        for(int f=0;f<n;++f) {
            float peak=0;
            for(int c=group.firstChannel;c>=0;c=cfg.nextProtectionChannel[c])if(c<outCount) {
                float& v=outputs[c][f];v=!state.discardUpstream && std::isfinite(v)?v:0;peak=std::max(peak,std::abs(v));
            }
            float gain=state.envelope.next(peak);minimumGain=std::min(minimumGain,gain);
            int member=0;
            for(int c=group.firstChannel;c>=0;c=cfg.nextProtectionChannel[c],++member) {
                float& delay=outputDelay_[c*ProtectionLookahead+state.head];
                float v=delay*gain;delay=c<outCount?outputs[c][f]:0;
                if(c<outCount)outputs[c][f]=v;
                // Telemetry represents every member, even overlapping pairs.
                if(member==0){peakL=std::max(peakL,std::abs(v));sumL+=double(v)*v;}
                else {peakR=std::max(peakR,std::abs(v));sumR+=double(v)*v;}
            }
            if(state.discardUpstream)--state.discardUpstream;
            if(++state.head==ProtectionLookahead)state.head=0;
        }
        outputMeters_[outputMeterSlots_[g]].writePeaks(peakL,peakR,sumL,sumR/std::max(1,group.channelCount-1),n,minimumGain);
    }
    completed_.store(cfg.generation,std::memory_order_release);
}
}
