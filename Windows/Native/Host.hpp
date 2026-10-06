#pragma once
#include "Session.hpp"
#include <memory>
namespace desk::windows {
class AudioHost {
public:
  virtual ~AudioHost() = default;
  virtual Json devices() = 0;
  virtual Json applications() = 0;
  virtual void start(const Json &) = 0;
  virtual void update(const Json &) = 0;
  virtual void loadSession(const Json &) = 0;
  virtual void stop() = 0;
  virtual Json status() = 0;
  virtual Json plugins(const std::string &, const Json &) = 0;
  virtual void resetMeter(const std::string &, bool) = 0;
};
std::unique_ptr<AudioHost> makeWindowsHost();
} // namespace desk::windows
