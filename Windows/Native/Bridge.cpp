#include "DeskWindows.h"
#include "Host.hpp"
#include <cstdlib>
#include <cstring>
using namespace desk::windows;
namespace {
struct Handle {
  std::unique_ptr<AudioHost> host;
  Handle() {
#ifdef _WIN32
    host = makeWindowsHost();
#endif
  }
};
} // namespace
extern "C" {
uint32_t mdw_abi_version() { return 1; }
void *mdw_create() {
  try {
    return new Handle;
  } catch (...) {
    return nullptr;
  }
}
void mdw_destroy(void *host) { delete static_cast<Handle *>(host); }
void mdw_free(char *text) { std::free(text); }
char *mdw_request(void *raw, const char *operation, const char *text) {
  Json response;
  try {
    if (!raw || !operation)
      throw std::invalid_argument("Invalid host or operation");
    if (text && std::strlen(text) > 128 * 1024 * 1024)
      throw std::invalid_argument("Control message exceeds 128 MB");
    auto args = Json::parse(text && *text ? text : "{}");
    auto &h = *static_cast<Handle *>(raw);
    std::string op = operation;
    Json result;
    if (op == "validate") {
      validateSession(args);
      result = true;
    } else {
      if (!h.host)
        throw std::runtime_error("Live Windows audio requires Windows 11 x64");
      if (op == "devices")
        result = h.host->devices();
      else if (op == "applications")
        result = h.host->applications();
      else if (op == "start")
        h.host->start(args);
      else if (op == "update")
        h.host->update(args);
      else if (op == "load")
        h.host->loadSession(args);
      else if (op == "stop")
        h.host->stop();
      else if (op == "status")
        result = h.host->status();
      else if (op == "resetMeter")
        h.host->resetMeter(args.value("id", ""), args.value("bus", false));
      else if (op == "scanPlugins" || op == "pluginParameters" ||
               op == "setParameter" || op == "pluginStates" ||
               op == "reloadPlugin")
        result = h.host->plugins(op, args);
      else
        throw std::invalid_argument("Unknown control operation");
    }
    response = {{"ok", true}, {"value", result}};
  } catch (const std::exception &e) {
    response = {{"ok", false}, {"error", e.what()}};
  } catch (...) {
    response = {{"ok", false}, {"error", "Unknown native error"}};
  }
  auto result = response.dump(-1, ' ', false, Json::error_handler_t::replace);
  auto *memory = static_cast<char *>(std::malloc(result.size() + 1));
  if (memory)
    std::memcpy(memory, result.c_str(), result.size() + 1);
  return memory;
}
}
