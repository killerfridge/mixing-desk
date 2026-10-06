#include "../Native/VstHost.hpp"
#include <cassert>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <objbase.h>
#include <windows.h>
using namespace desk::windows;
int main(int argc, char **argv) {
  assert(argc == 2);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  {
    auto catalog = inspectVst(argv[1]);
    assert(catalog.size() == 2); // Instrument and controller are not effects.
    Json slot = {{"id", "insert"},
                 {"format", "vst3"},
                 {"identifier", catalog[0]["id"]},
                 {"bypassed", false}};
    Json owner = {
        {"id", "strip"},
        {"source",
         {{"kind", "device"}, {"deviceUID", "test"}, {"channels", {0, 1}}}},
        {"inserts", Json::array({slot})}};
    Json session = {{"strips", Json::array({owner})}, {"buses", Json::array()}};
    PluginRack rack;
    rack.setTestCatalog(catalog);
    rack.prepare(session, 1);
    auto status = rack.status();
    assert(status[0]["available"] == true);
    auto *processor = rack.processor(slot, false);
    assert(processor);
    float l[128], r[128];
    float *audio[] = {l, r};
    auto render = [&] {
      std::fill_n(l, 128, .2f);
      std::fill_n(r, 128, .4f);
      processor->process(audio, 2, 128);
    };
    render();
    assert(std::abs(l[127] - .1f) < 1e-5 && std::abs(r[127] - .2f) < 1e-5);
    rack.edit("insert", 0, .25);
    render();
    assert(std::abs(l[127] - .05f) < 1e-5);
    rack.status();
    auto parameters = rack.parameters("insert");
    assert(parameters[2]["value"] == .75);
    rack.edit("insert", 1, 1);
    rack.status();
    assert(processor->latencyFrames() == 19);
    auto state = rack.states()["insert"];
    assert(state["component"].is_string());
    // Pending edits survive an immediate save before the next process block.
    rack.edit("insert", 0, .8);
    state = rack.states()["insert"];
    assert(state["parameters"].size() > 0);
    session["strips"][0]["inserts"][0]["nativeState"] = state;
    PluginRack restored;
    restored.setTestCatalog(catalog);
    restored.prepare(session, 1);
    assert(restored.status()[0]["available"] == true);
    processor = restored.processor(slot, false);
    render();
    assert(std::abs(l[127] - .16f) < 1e-5);
    processor->setBypassed(true);
    for (int n = 0; n < 4; ++n)
      render();
    assert(std::abs(l[127] - .2f) < 1e-5);
    // Parameter edits do not recreate plugins; context edits do and retain
    // state.
    auto *previous = rack.processor(slot, false);
    rack.prepare(session, 2);
    assert(previous == rack.processor(slot, false));
    session["strips"][0]["source"]["deviceUID"] = "changed";
    rack.prepare(session, 2);
    assert(previous != rack.processor(slot, false));
    rack.collect(2);
    session["strips"][0]["inserts"][0]["identifier"] =
        "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";
    restored.prepare(session, 3);
    processor = restored.processor(slot, false);
    render();
    assert(l[127] == 0);
    assert(restored.status()[0]["available"] == false);
    processor->setBypassed(true);
    for (int n = 0; n < 4; ++n)
      render();
    assert(std::abs(l[127] - .2f) < 1e-5);
    restored.collect(3);
  }
  CoUninitialize();
  std::cout
      << "PASS: Windows VST3 ABI, isolated fixture discovery, lifecycle, "
         "parameters, latency "
         "restart, state, bypass, missing-plugin silence and retirement.\n";
}
