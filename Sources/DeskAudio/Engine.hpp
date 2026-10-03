#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "Equalizer.hpp"

namespace desk {
constexpr int MaxStrips = 64, MaxBuses = 16, MaxChannels = 512, MaxFrames = 4096;
constexpr int MaxSends = MaxBuses, MaxRoutes = 512;
struct Send { int bus = -1; float gain = 1; bool pre = false; };
struct Strip {
    uint64_t identity = 0, sourceIdentity = 0;
    int left = -1, right = -1;
    float trim = 1, fader = 1, pan = 0;
    bool mono = true, polarity = false, mute = false, solo = false, directGuitar = false;
    int sendCount = 0;
    std::array<Send, MaxSends> sends{};
    int insertCount=0;
    std::array<InsertConfiguration,MaxInserts> inserts{};
};
struct Bus {
    uint64_t identity = 0, excludedSource = 0;
    float gain = 1; bool mute = false, monitor = false;
    int sendCount = 0;
    std::array<Send, MaxSends> sends{};
    int insertCount=0;
    std::array<InsertConfiguration,MaxInserts> inserts{};
    bool externalInserts=false;
};
struct Route {
    bool fromBus = true, pre = false;
    int source = 0, left = -1, right = -1;
    float gain = 1;
    uint64_t identity = 0;
};
struct Configuration {
    uint64_t generation=0;
    int stripCount = 0, busCount = 0, routeCount = 0;
    std::array<Strip, MaxStrips> strips{};
    std::array<Bus, MaxBuses> buses{};
    std::array<Route, MaxRoutes> routes{};
    std::array<int, MaxBuses> busOrder{};
    bool validate(std::string& error);
};
struct Meter { float peakL = 0, peakR = 0, rmsL = 0, rmsR = 0; bool clip = false; };
class Engine {
public:
    Engine();
    ~Engine();
    // Exactly one serialized control-thread writer, one render-thread reader.
    bool publish(const Configuration& config, std::string& error);
    void render(const float* const* input, int inputCount, float* const* output, int outputCount, int frames) noexcept;
    Meter stripMeter(int index) const noexcept;
    Meter busMeter(int index) const noexcept;
    void clearClip() noexcept;
    // Call only while audio is stopped, to clear effect histories on restart.
    void reset() noexcept;
    uint64_t publishedGeneration() const noexcept {return published_;}
    uint64_t completedGeneration() const noexcept {return completed_.load(std::memory_order_acquire);}
    void activateStopped() noexcept;
private:
    struct MeterSlot {
        std::atomic<float> peakL{0}, peakR{0}, rmsL{0}, rmsR{0};
        std::atomic<bool> clip{false};
        void write(const float*, const float*, int) noexcept;
        Meter read() const noexcept;
    };
    struct Smooth {
        float value = 0, target = 0, step = 0; int remaining = 0;
        void set(float next) noexcept;
        float next() noexcept;
    };
    struct StripState { uint64_t identity = 0; Smooth trim, fader, left, right, mute; std::array<Smooth, MaxSends> sends; };
    struct BusState { uint64_t identity = 0; Smooth gain; std::array<Smooth, MaxSends> sends; bool external=false; };
    // Triple-buffer mailbox. Ownership transfers via a single atomic exchange.
    std::array<Configuration, 3> configs_{};
    int controlSlot_ = 1, renderSlot_ = 0;
    std::atomic<int> mailbox_{2};
    uint64_t published_=0;
    std::atomic<uint64_t> completed_{0};
    static constexpr int Dirty = 4;
    std::array<StripState, MaxStrips> stripState_{};
    std::array<BusState, MaxBuses> busState_{};
    struct RouteState { uint64_t identity = 0; Smooth gain; };
    std::array<RouteState, MaxRoutes> routeState_{};
    std::array<MeterSlot, MaxStrips> stripMeters_{};
    std::array<MeterSlot, MaxBuses> busMeters_{};
    // Scratch allocations occur once, never on the render thread.
    std::unique_ptr<float[]> scratch_;
    std::unique_ptr<InsertChain[]> stripInserts_,busInserts_,terminalInserts_;
};
float dbGain(float db) noexcept;
}
