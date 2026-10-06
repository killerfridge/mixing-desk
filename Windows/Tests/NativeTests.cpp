#include "../Native/ClockQueue.hpp"
#include "../Native/Session.hpp"
#include <cassert>
#include <iostream>
using namespace desk::windows;
Json starter() {
  Json source = {{"kind", "device"},
                 {"deviceUID", "win:mic"},
                 {"bundleID", ""},
                 {"returnBundleID", ""},
                 {"channels", {0}}};
  Json strip = {
      {"id", "s"},
      {"name", "Mic"},
      {"color", "teal"},
      {"role", "generic"},
      {"source", source},
      {"trimDB", 0},
      {"faderDB", 0},
      {"pan", 0},
      {"polarity", false},
      {"muted", false},
      {"solo", false},
      {"sends",
       Json::array({{{"busID", "m"}, {"gainDB", 0}, {"preFader", false}}})},
      {"inserts", Json::array()}};
  Json bus = {{"id", "m"},
              {"name", "Monitor"},
              {"kind", "monitor"},
              {"gainDB", 0},
              {"muted", false},
              {"excludedStripID", ""},
              {"sends", Json::array()},
              {"inserts", Json::array()}};
  return {{"version", 1},
          {"name", "Test"},
          {"monitorDeviceUID", "win:out"},
          {"bufferFrames", 128},
          {"monitoringMode", "mixer"},
          {"strips", Json::array({strip})},
          {"buses", Json::array({bus})},
          {"routes", Json::array({{{"id", "r"},
                                   {"sourceKind", "bus"},
                                   {"sourceID", "m"},
                                   {"preFader", false},
                                   {"destinationUID", "win:out"},
                                   {"channels", {0, 1}},
                                   {"gainDB", 0}}})}};
}
int main() {
  auto s = starter();
  validateSession(s);
  auto c = compileSession(
      s, {{"win:mic", {0, 1}}}, {{"win:out", {0, 2}}},
      [](auto &, bool) -> desk::InsertProcessor * { return nullptr; });
  assert(c->strips[0].left == 0 && c->routes[0].right == 1 &&
         c->outputProtectionEnabled && c->strips[0].limiterEnabled);
  auto offline =
      compileSession(s, {}, {}, [](auto &, bool) -> desk::InsertProcessor * {
        return nullptr;
      });
  assert(offline->strips[0].left == -1 && offline->routes[0].left == -1);
  auto reject = [](const Json &s) {
    try {
      validateSession(s);
    } catch (const std::exception &) {
      return;
    }
    assert(false);
  };
  auto bad = s;
  bad["strips"][0]["id"] = "m";
  reject(bad);
  bad = s;
  bad["bufferFrames"] = 17;
  reject(bad);
  bad = s;
  bad["buses"][0]["sends"] =
      Json::array({{{"busID", "m"}, {"gainDB", 0}, {"preFader", false}}});
  reject(bad);
  for (int n = 0; n < 256; ++n) {
    std::vector<uint8_t> bytes;
    for (int j = 0; j < n; ++j)
      bytes.push_back(uint8_t(j));
    assert(unbase64(base64(bytes)) == bytes);
  }
  // Faster and slower sources: bounded reservoir, finite continuous output,
  // no recurring underruns after priming, and correction in the right
  // direction.
  for (double drift : {-.001, .001}) {
    ClockQueue q(2, 1440);
    std::vector<float> input(2048), output(960);
    double carry = 0;
    uint64_t sample = 0;
    float previous = 0;
    bool heard = false;
    for (int block = 0; block < 12000; ++block) {
      carry += 480 * (1 + drift);
      int n = int(carry);
      carry -= n;
      for (int f = 0; f < n; ++f) {
        float x = .1f * std::sin(double(sample++) * .02);
        input[f * 2] = input[f * 2 + 1] = x;
      }
      q.push(input.data(), n);
      q.pull(output.data(), 480);
      for (float value : output) {
        assert(std::isfinite(value));
        if (block > 100 && heard)
          assert(std::abs(value - previous) < .015f);
        previous = value;
        if (std::abs(value) > .001)
          heard = true;
      }
      assert(q.buffered() < 8000);
    }
    assert(q.underruns == 0 && q.overruns == 0);
    assert(q.correction() * drift > 0);
    q.reset();
    q.pull(output.data(), 480);
    for (float x : output)
      assert(x == 0);
  }
  std::cout << "PASS: Windows session compilation, offline bindings, "
               "validation, base64, and "
               "independent-clock drift simulation.\n";
}
