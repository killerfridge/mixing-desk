#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <samplerate.h>
#include <stdexcept>
#include <vector>
namespace desk::windows {
// Single audio-thread owner. Separate device clocks are reconciled against the
// selected monitor clock; a bounded reservoir absorbs scheduling jitter. All
// storage and resampler history are allocated before any endpoint starts.
class ClockQueue {
  int channels_;
  long capacity_, target_, head_ = 0, size_ = 0;
  bool primed_ = false;
  std::vector<float> ring_, scratch_;
  SRC_STATE *resampler_ = nullptr;
  double correction_ = 0;

public:
  uint64_t underruns = 0, overruns = 0;
  ClockQueue(int channels, int target)
      : channels_(channels), capacity_(std::max(16384, target * 8)),
        target_(std::max(512, target)), ring_(capacity_ * channels),
        scratch_(capacity_ * channels) {
    int error = 0;
    resampler_ = src_new(SRC_SINC_FASTEST, channels, &error);
    if (!resampler_)
      throw std::runtime_error(src_strerror(error));
  }
  ~ClockQueue() { src_delete(resampler_); }
  ClockQueue(const ClockQueue &) = delete;
  ClockQueue &operator=(const ClockQueue &) = delete;
  long buffered() const { return size_; }
  double correction() const { return correction_; }
  void reset() {
    head_ = size_ = 0;
    primed_ = false;
    correction_ = 0;
    src_reset(resampler_);
  }
  void push(const float *data, int frames) {
    if (frames > capacity_) {
      if (data)
        data += size_t(frames - capacity_) * channels_;
      frames = int(capacity_);
    }
    if (size_ + frames > capacity_) {
      ++overruns;
      reset();
    }
    for (int f = 0; f < frames; ++f)
      for (int c = 0; c < channels_; ++c) {
        float x = data ? data[size_t(f) * channels_ + c] : 0;
        ring_[size_t((head_ + size_ + f) % capacity_) * channels_ + c] =
            std::isfinite(x) ? x : 0;
      }
    size_ += frames;
  }
  void pull(float *out, int frames) {
    std::fill_n(out, size_t(frames) * channels_, 0.f);
    if (!primed_) {
      if (size_ < target_ + frames)
        return;
      primed_ = true;
    }
    // Correct at most 0.5%, gradually. This exceeds normal oscillator error
    // without responding audibly to individual callback timing variations.
    double desired = std::clamp(
        double(size_ - target_ - frames) / double(target_) * .002, -.005, .005);
    correction_ += std::clamp(desired - correction_, -.000005, .000005);
    for (long f = 0; f < size_; ++f)
      std::copy_n(&ring_[size_t((head_ + f) % capacity_) * channels_],
                  channels_, &scratch_[size_t(f) * channels_]);
    SRC_DATA d{};
    d.data_in = scratch_.data();
    d.input_frames = size_;
    d.data_out = out;
    d.output_frames = frames;
    d.src_ratio = 1.0 / (1.0 + correction_);
    int error = src_process(resampler_, &d);
    head_ = (head_ + d.input_frames_used) % capacity_;
    size_ -= d.input_frames_used;
    if (error || d.output_frames_gen < frames) {
      ++underruns;
      reset();
    }
  }
};
} // namespace desk::windows
