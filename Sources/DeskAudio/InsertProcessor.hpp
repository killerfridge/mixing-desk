#pragma once
#include <cstdint>
#include <vector>

namespace desk {
// Preparation and serialization are control-thread operations. process/reset and
// bypass changes must not allocate, lock, or call the host.
class InsertProcessor {
public:
    virtual ~InsertProcessor() = default;
    virtual void prepare(double sampleRate, uint32_t maxFrames, uint32_t channels) = 0;
    virtual void process(float* const* audio, uint32_t channels, uint32_t frames) noexcept = 0;
    virtual void reset() noexcept = 0;
    virtual void setBypassed(bool) noexcept = 0;
    virtual uint32_t latencyFrames() const noexcept = 0;
    virtual std::vector<uint8_t> saveState() const = 0;
    virtual void restoreState(const std::vector<uint8_t>&) = 0;
};
}
