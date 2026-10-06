#pragma once
#include <algorithm>
#include <array>
#include <cmath>

namespace desk {
constexpr int ProtectionLookahead = 48;
constexpr int ProtectionLatency = 2 * ProtectionLookahead;
constexpr float ProtectionCeiling = 0.891250938f; // -1 dBFS sample peak, at 48 kHz.

// A future peak schedules a smoothstep attack over the delayed samples leading
// up to it. Taking the minimum of all scheduled envelopes guarantees that each
// peak reaches its required attenuation, including across callback boundaries.
// Recovery is exponential with a 100 ms time constant. No makeup gain.
struct LookaheadGain {
    std::array<float, ProtectionLookahead + 1> caps{};
    float gain = 1, blend = 1, blendTarget = 1, blendStep = 0;
    int head = 0, blendRemaining = 0;
    inline static const std::array<float, ProtectionLookahead + 1> attack = [] {
        std::array<float, ProtectionLookahead + 1> result{};
        for (int i = 0; i <= ProtectionLookahead; ++i) {
            float x = float(i) / ProtectionLookahead;
            result[i] = x*x*(3-2*x);
        }
        return result;
    }();
    static constexpr float Release = 0.999791688f; // exp(-1 / (48000 * .100))
    LookaheadGain() noexcept { reset(true); }
    void reset(bool enabled) noexcept {
        caps.fill(1); gain = 1; head = 0;
        blend = blendTarget = enabled ? 1 : 0; blendStep = 0; blendRemaining = 0;
    }
    void enable(bool enabled) noexcept {
        float target = enabled ? 1 : 0;
        if (target != blendTarget) {
            blendTarget = target; blendRemaining = 240;
            blendStep = (target - blend) / blendRemaining;
        }
    }
    float next(float peak) noexcept {
        if (peak > ProtectionCeiling) {
            // A little rounding margin keeps multiplied float samples bounded.
            float required = (ProtectionCeiling / peak) * 0.99999988f;
            int slot = head;
            for (int i = 0; i <= ProtectionLookahead; ++i) {
                caps[slot] = std::min(caps[slot], (1-attack[i])+required*attack[i]);
                if (++slot > ProtectionLookahead) slot = 0;
            }
            // Avoid cancellation when required is very small.
            int tail = head ? head - 1 : ProtectionLookahead;
            caps[tail] = std::min(caps[tail], required);
        }
        gain = std::min(caps[head], 1-(1-gain)*Release);
        caps[head] = 1;
        if (++head > ProtectionLookahead) head = 0;
        if (blendRemaining) { blend += blendStep; if (!--blendRemaining) blend = blendTarget; }
        return blend == 1 ? gain : blend == 0 ? 1 : 1-(1-gain)*blend;
    }
};
struct StereoProtection {
    LookaheadGain envelope;
    std::array<float, ProtectionLookahead> left{}, right{};
    int head = 0;
    void reset(bool enabled) noexcept { left.fill(0); right.fill(0); head = 0; envelope.reset(enabled); }
    void enable(bool enabled) noexcept { envelope.enable(enabled); }
    float process(float& l, float& r) noexcept {
        l = std::isfinite(l) ? l : 0; r = std::isfinite(r) ? r : 0;
        float gain = envelope.next(std::max(std::abs(l), std::abs(r)));
        float dl = left[head], dr = right[head]; left[head] = l; right[head] = r;
        if (++head == ProtectionLookahead) head = 0;
        l = dl*gain; r = dr*gain;
        return gain;
    }
};
}
