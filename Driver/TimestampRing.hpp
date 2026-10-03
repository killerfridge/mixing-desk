#pragma once
#include <atomic>
#include <bit>
#include <cstdint>
#include <memory>
#include <limits>

namespace desk {
// One HAL mix writer, multiple independent readers. Atomic samples make wraparound
// races well-defined; the frame stamp is rechecked after the copy. Missing data is zero.
class TimestampRing {
    static constexpr int Capacity=16384;
    int channels_;
    std::unique_ptr<std::atomic<uint32_t>[]> samples_;
    std::unique_ptr<std::atomic<int64_t>[]> stamps_;
public:
    explicit TimestampRing(int channels) : channels_(channels), samples_(new std::atomic<uint32_t>[Capacity*channels]{}), stamps_(new std::atomic<int64_t>[Capacity]) {
        invalidate();
    }
    void invalidate() noexcept {for(int i=0;i<Capacity;++i)stamps_[i].store(std::numeric_limits<int64_t>::min(),std::memory_order_seq_cst);}
    void write(int64_t time,const float* input,int frames) noexcept {
        if(frames>Capacity)return;
        for(int f=0;f<frames;++f) {
            int i=uint64_t(time+f)%Capacity;
            stamps_[i].store(std::numeric_limits<int64_t>::min(),std::memory_order_seq_cst);
            for(int c=0;c<channels_;++c)samples_[i*channels_+c].store(std::bit_cast<uint32_t>(input[f*channels_+c]),std::memory_order_seq_cst);
            stamps_[i].store(time+f,std::memory_order_seq_cst);
        }
    }
    void read(int64_t time,float* output,int frames) const noexcept {
        for(int f=0;f<frames;++f) {
            int i=uint64_t(time+f)%Capacity;bool valid=stamps_[i].load(std::memory_order_seq_cst)==time+f;
            for(int c=0;c<channels_;++c)output[f*channels_+c]=valid ? std::bit_cast<float>(samples_[i*channels_+c].load(std::memory_order_seq_cst)) : 0;
            if(stamps_[i].load(std::memory_order_seq_cst)!=time+f)for(int c=0;c<channels_;++c)output[f*channels_+c]=0;
        }
    }
};
static_assert(std::atomic<uint32_t>::is_always_lock_free && std::atomic<int64_t>::is_always_lock_free);
}
