#include "Session.hpp"
#include <set>
#include <stdexcept>
namespace desk::windows {
namespace {
void require(bool yes, const char *message) {
  if (!yes)
    throw std::invalid_argument(message);
}
int find(const Json &items, const std::string &id) {
  for (size_t i = 0; i < items.size(); ++i)
    if (items[i].at("id") == id)
      return int(i);
  return -1;
}
double number(const Json &j, const char *key, double lo, double hi) {
  double n = j.at(key).get<double>();
  require(std::isfinite(n) && n >= lo && n <= hi, "Invalid numeric setting");
  return n;
}
void channels(const Json &j) {
  require(j.is_array() && j.size() >= 1 && j.size() <= 2,
          "Choose mono or stereo channels");
  std::set<int> seen;
  for (auto &n : j) {
    require(n.is_number_integer(), "Invalid channel number");
    int c = n.get<int>();
    require(c >= 0 && c < MaxChannels && seen.insert(c).second,
            "Invalid or repeated channel");
  }
}
} // namespace
uint64_t identity(const std::string &value) {
  uint64_t h = 1469598103934665603ULL;
  for (unsigned char c : value)
    h = (h ^ c) * 1099511628211ULL;
  return h ? h : 1;
}
std::string sourceKey(const Json &s) {
  return s.at("kind") == "application"
             ? "app:" + s.at("bundleID").get<std::string>()
         : s.value("returnBundleID", "").empty()
             ? "device:" + s.at("deviceUID").get<std::string>()
             : "app:" + s.at("returnBundleID").get<std::string>();
}
std::vector<uint8_t> unbase64(const std::string &text) {
  require(text.size() <= 24 * 1024 * 1024, "State exceeds size limit");
  require(text.size() % 4 == 0, "Invalid base64 length");
  std::vector<uint8_t> out;
  out.reserve(text.size() / 4 * 3);
  int bits = 0, count = 0;
  bool ended = false;
  for (unsigned char c : text) {
    if (c == '=') {
      ended = true;
      continue;
    }
    require(!ended, "Invalid base64 padding");
    int n = c >= 'A' && c <= 'Z'   ? c - 'A'
            : c >= 'a' && c <= 'z' ? c - 'a' + 26
            : c >= '0' && c <= '9' ? c - '0' + 52
            : c == '+'             ? 62
            : c == '/'             ? 63
                                   : -1;
    require(n >= 0, "Invalid base64");
    bits = (bits << 6) | n;
    count += 6;
    if (count >= 8) {
      count -= 8;
      out.push_back(uint8_t(bits >> count));
      bits &= (1 << count) - 1;
    }
  }
  return out;
}
std::string base64(const std::vector<uint8_t> &bytes) {
  static constexpr char table[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve((bytes.size() + 2) / 3 * 4);
  for (size_t i = 0; i < bytes.size(); i += 3) {
    uint32_t n = uint32_t(bytes[i]) << 16;
    if (i + 1 < bytes.size())
      n |= uint32_t(bytes[i + 1]) << 8;
    if (i + 2 < bytes.size())
      n |= bytes[i + 2];
    out += table[n >> 18];
    out += table[(n >> 12) & 63];
    out += i + 1 < bytes.size() ? table[(n >> 6) & 63] : '=';
    out += i + 2 < bytes.size() ? table[n & 63] : '=';
  }
  return out;
}
void validateSession(const Json &s) {
  require(s.at("version") == 1, "Unsupported session version");
  const auto &strips = s.at("strips");
  const auto &buses = s.at("buses");
  const auto &routes = s.at("routes");
  require(strips.is_array() && buses.is_array() && routes.is_array(),
          "Invalid session lists");
  require(strips.size() <= MaxStrips && buses.size() <= MaxBuses &&
              routes.size() <= MaxRoutes,
          "Mixer capacity exceeded");
  int frames = s.at("bufferFrames").get<int>();
  require(frames >= 32 && frames <= MaxFrames && (frames & (frames - 1)) == 0,
          "Invalid buffer size");
  require(s.at("monitoringMode") == "mixer" ||
              s.at("monitoringMode") == "directGuitar",
          "Invalid monitoring mode");
  std::set<std::string> ids, taps, returns;
  int monitors = 0;
  auto id = [&](const Json &j) {
    auto value = j.at("id").get<std::string>();
    require(!value.empty() && ids.insert(value).second,
            "Session IDs must be unique");
  };
  auto sends = [&](const Json &j) {
    require(j.is_array() && j.size() <= MaxSends, "Too many sends");
    std::set<std::string> seen;
    for (auto &send : j) {
      auto b = send.at("busID").get<std::string>();
      require(find(buses, b) >= 0 && seen.insert(b).second,
              "Invalid send destination");
      number(send, "gainDB", -90, 24);
      send.at("preFader").get<bool>();
    }
  };
  auto inserts = [&](const Json &owner) {
    auto slots = owner.value("inserts", Json::array());
    require(slots.is_array() && slots.size() <= MaxInserts,
            "Up to four inserts per owner");
    for (auto &slot : slots) {
      id(slot);
      auto f = slot.at("format").get<std::string>();
      auto name = slot.at("identifier").get<std::string>();
      require(f == "au" || f == "vst3" ||
                  (f == "builtin" && name == "local.mixingdesk.eq"),
              "Unsupported insert");
      if (f == "vst3")
        require(name.size() == 32 &&
                    name.find_first_not_of("0123456789ABCDEF") ==
                        std::string::npos,
                "Invalid VST3 class ID");
      if (slot.contains("state") && !slot["state"].is_null())
        require(unbase64(slot["state"].get<std::string>()).size() <=
                    16 * 1024 * 1024,
                "Plugin state exceeds 16 MB");
    }
  };
  for (auto &strip : strips) {
    id(strip);
    number(strip, "trimDB", -90, 24);
    number(strip, "faderDB", -90, 24);
    number(strip, "pan", -1, 1);
    auto &src = strip.at("source");
    require(src.at("kind") == "device" || src.at("kind") == "application",
            "Invalid source kind");
    channels(src.at("channels"));
    if (src.at("kind") == "application" && !src.value("bundleID", "").empty())
      taps.insert(src["bundleID"]);
    if (!src.value("returnBundleID", "").empty())
      returns.insert(src["returnBundleID"]);
    sends(strip.at("sends"));
    inserts(strip);
  }
  for (auto &key : taps)
    require(
        !returns.count(key),
        "An application cannot use both direct capture and a virtual return");
  for (auto &bus : buses) {
    id(bus);
    number(bus, "gainDB", -90, 24);
    std::string kind = bus.at("kind");
    require(kind == "monitor" || kind == "call" || kind == "mix",
            "Invalid bus kind");
    monitors += kind == "monitor";
    auto excluded = bus.value("excludedStripID", "");
    require(excluded.empty() || find(strips, excluded) >= 0,
            "Missing excluded source");
    sends(bus.at("sends"));
    inserts(bus);
    for (auto &slot : bus.value("inserts", Json::array()))
      if (slot.at("format") != "builtin")
        require(bus.at("sends").empty(),
                "Plugin buses cannot send to other buses");
  }
  require(monitors == 1, "Exactly one Monitor bus is required");
  std::set<std::string> active, visited;
  std::function<void(const Json &)> visit = [&](const Json &bus) {
    std::string key = bus.at("id");
    require(!active.count(key), "Routing would create a feedback cycle");
    if (visited.count(key))
      return;
    active.insert(key);
    for (auto &send : bus.at("sends"))
      visit(buses[find(buses, send.at("busID"))]);
    active.erase(key);
    visited.insert(key);
  };
  for (auto &bus : buses)
    visit(bus);
  for (auto &route : routes) {
    id(route);
    require(route.at("sourceKind") == "bus" ||
                route.at("sourceKind") == "strip",
            "Invalid route kind");
    require(find(route.at("sourceKind") == "bus" ? buses : strips,
                 route.at("sourceID")) >= 0,
            "Missing route source");
    number(route, "gainDB", -90, 24);
    channels(route.at("channels"));
    route.at("destinationUID").get<std::string>();
  }
}
std::unique_ptr<Configuration> compileSession(
    const Json &s, const Bindings &inputs, const Bindings &outputs,
    const std::function<InsertProcessor *(const Json &, bool)> &plugin) {
  validateSession(s);
  auto cfg = std::make_unique<Configuration>();
  auto &c = *cfg;
  const auto &strips = s.at("strips");
  const auto &buses = s.at("buses");
  c.stripCount = int(strips.size());
  c.busCount = int(buses.size());
  c.routeCount = int(s.at("routes").size());
  c.outputProtectionEnabled = s.value("outputProtectionEnabled", true);
  auto inserts = [&](const Json &owner, auto &result, bool mono) {
    auto slots = owner.value("inserts", Json::array());
    result.insertCount = int(slots.size());
    for (size_t i = 0; i < slots.size(); ++i) {
      const auto &slot = slots[i];
      auto &insert = result.inserts[i];
      insert.identity = identity(slot.at("id"));
      insert.bypassed = slot.at("bypassed");
      if (slot.at("format") != "builtin") {
        insert.external = plugin(slot, mono);
        require(insert.external != nullptr, "Plugin preparation failed");
      } else if (slot.contains("state") && !slot["state"].is_null()) {
        auto bytes = unbase64(slot["state"]);
        auto p = Json::parse(bytes);
        require(p.at("version") == 1, "Unsupported EQ state");
        insert.parameters = {p.at("lowFrequency"), p.at("lowGain"),
                             p.at("midFrequency"), p.at("midGain"),
                             p.at("midQ"),         p.at("highFrequency"),
                             p.at("highGain"),     p.at("outputGain")};
      }
    }
  };
  auto sends = [&](const Json &owner, auto &result) {
    result.sendCount = int(owner.at("sends").size());
    for (int j = 0; j < result.sendCount; ++j) {
      const auto &send = owner["sends"][j];
      result.sends[j] = {find(buses, send.at("busID")),
                         dbGain(send.at("gainDB")), send.at("preFader")};
    }
  };
  auto patch = [&](const Bindings &bindings, const std::string &key,
                   const Json &ch, int &l, int &r) {
    auto it = bindings.find(key);
    if (it == bindings.end())
      return;
    int a = ch[0];
    if (a < it->second.channels)
      l = it->second.offset + a;
    if (ch.size() > 1) {
      int b = ch[1];
      if (b < it->second.channels)
        r = it->second.offset + b;
    }
  };
  for (int i = 0; i < c.stripCount; ++i) {
    auto &a = strips[i];
    auto &b = c.strips[i];
    auto &src = a.at("source");
    b.identity = identity(a.at("id"));
    b.sourceIdentity = identity(sourceKey(src));
    b.mono = src.at("channels").size() == 1;
    patch(inputs,
          src.at("kind") == "application" ? src.at("bundleID")
                                          : src.at("deviceUID"),
          src.at("channels"), b.left, b.right);
    b.trim = dbGain(a.at("trimDB"));
    b.fader = dbGain(a.at("faderDB"));
    b.pan = a.at("pan");
    b.mute = a.at("muted");
    b.solo = a.at("solo");
    b.polarity = a.at("polarity");
    b.limiterEnabled = a.value("limiterEnabled", true);
    b.directGuitar =
        s.at("monitoringMode") == "directGuitar" && a.at("role") == "guitar";
    sends(a, b);
    inserts(a, b, b.mono);
  }
  for (int i = 0; i < c.busCount; ++i) {
    auto &a = buses[i];
    auto &b = c.buses[i];
    b.identity = identity(a.at("id"));
    b.gain = dbGain(a.at("gainDB"));
    b.mute = a.at("muted");
    b.monitor = a.at("kind") == "monitor";
    int excluded = find(strips, a.value("excludedStripID", ""));
    if (excluded >= 0)
      b.excludedSource = c.strips[excluded].sourceIdentity;
    sends(a, b);
    inserts(a, b, false);
  }
  for (int i = 0; i < c.routeCount; ++i) {
    auto &a = s["routes"][i];
    auto &b = c.routes[i];
    b.identity = identity(a.at("id"));
    b.fromBus = a.at("sourceKind") == "bus";
    b.source = find(b.fromBus ? buses : strips, a.at("sourceID"));
    b.pre = a.at("preFader");
    b.gain = dbGain(a.at("gainDB"));
    patch(outputs, a.at("destinationUID"), a.at("channels"), b.left, b.right);
  }
  for (auto &[key, b] : outputs) {
    require(b.offset >= 0 && b.channels >= 0 &&
                b.offset + b.channels <= MaxChannels,
            "Output channel capacity exceeded");
    for (int ch = 0; ch < b.channels; ++ch)
      c.outputIdentities[b.offset + ch] =
          identity(key + ":" + std::to_string(ch));
  }
  std::string error;
  require(c.validate(error), error.c_str());
  return cfg;
}
Json meterJson(Meter m, const std::string &id) {
  return {
      {"id", id},         {"peakL", m.peakL}, {"peakR", m.peakR},
      {"rmsL", m.rmsL},   {"rmsR", m.rmsR},   {"heldL", m.heldL},
      {"heldR", m.heldR}, {"clip", m.clip},   {"reductionDB", m.reductionDB}};
}
} // namespace desk::windows
