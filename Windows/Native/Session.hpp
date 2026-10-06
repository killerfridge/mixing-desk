#pragma once
#include "Engine.hpp"
#include <functional>
#include <map>
#include <nlohmann/json.hpp>
namespace desk::windows {
using Json = nlohmann::json;
struct Binding {
  int offset = 0, channels = 0;
};
using Bindings = std::map<std::string, Binding>;
uint64_t identity(const std::string &value);
std::string sourceKey(const Json &source);
void validateSession(const Json &session);
std::unique_ptr<Configuration> compileSession(
    const Json &session, const Bindings &inputs, const Bindings &outputs,
    const std::function<InsertProcessor *(const Json &, bool)> &plugin);
Json meterJson(Meter meter, const std::string &id);
std::vector<uint8_t> unbase64(const std::string &text);
std::string base64(const std::vector<uint8_t> &bytes);
} // namespace desk::windows
