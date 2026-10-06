#include "VstHost.hpp"
#include "VST3Support.hpp"
#include <filesystem>
#include <fstream>
#include <set>
#include <thread>
#include <windows.h>
namespace desk::windows {
using namespace desk::vst3;
namespace {
std::wstring wide(const std::string &s) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              int(s.size()), nullptr, 0);
  std::wstring out(n, 0);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()),
                      out.data(), n);
  return out;
}
std::string utf8(const std::wstring &s) {
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), int(s.size()), nullptr, 0,
                              nullptr, nullptr);
  std::string out(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, s.data(), int(s.size()), out.data(), n,
                      nullptr, nullptr);
  return out;
}
std::string text16(const char16_t *s) {
  return utf8(std::wstring(reinterpret_cast<const wchar_t *>(s)));
}
std::string classID(const TUID id) {
  char s[33]{};
  FUID::fromTUID(id).toString(s);
  return s;
}
void check(tresult n, const char *what) {
  if (n != kResultOk)
    throw std::runtime_error(std::string(what) + " (" + std::to_string(n) +
                             ")");
}
Host hostContext;
struct Module {
  HMODULE handle = nullptr;
  IPluginFactory *factory = nullptr;
  bool entered = false;
  explicit Module(const std::string &path) {
    auto p = std::filesystem::path(wide(path));
    if (std::filesystem::is_directory(p))
      p = p / L"Contents" / L"x86_64-win" / (p.stem().wstring() + L".vst3");
    handle = LoadLibraryExW(p.c_str(), nullptr,
                            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                                LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!handle)
      throw std::runtime_error("Cannot load x64 VST3 module (" +
                               std::to_string(GetLastError()) + ")");
    auto init = reinterpret_cast<bool (*)()>(GetProcAddress(handle, "InitDll"));
    auto get = reinterpret_cast<IPluginFactory *(*)()>(
        GetProcAddress(handle, "GetPluginFactory"));
    if ((init && !(entered = init())) || !get) {
      FreeLibrary(handle);
      handle = nullptr;
      throw std::runtime_error("Invalid VST3 module entry");
    }
    factory = get();
    if (!factory) {
      if (entered) {
        auto exit =
            reinterpret_cast<bool (*)()>(GetProcAddress(handle, "ExitDll"));
        if (exit)
          exit();
      }
      FreeLibrary(handle);
      handle = nullptr;
      throw std::runtime_error("VST3 factory is unavailable");
    }
    if (auto *f = query<IPluginFactory3>(factory)) {
      f->setHostContext(&hostContext);
      f->release();
    }
  }
  ~Module() {
    release(factory);
    if (handle) {
      auto exit =
          reinterpret_cast<bool (*)()>(GetProcAddress(handle, "ExitDll"));
      if (entered && exit)
        exit();
      FreeLibrary(handle);
    }
  }
};
std::map<std::string, std::weak_ptr<Module>> modules;
std::shared_ptr<Module> load(const std::string &path) {
  auto &ref = modules[path];
  if (auto p = ref.lock())
    return p;
  auto p = std::make_shared<Module>(path);
  ref = p;
  return p;
}
class Effect;
class Handler final : public IComponentHandler {
  std::atomic<uint32> refs{1};

public:
  Effect *owner = nullptr;
  uint32 PLUGIN_API addRef() override { return ++refs; }
  uint32 PLUGIN_API release() override {
    auto n = --refs;
    if (!n)
      delete this;
    return n;
  }
  tresult PLUGIN_API queryInterface(const TUID id, void **out) override {
    if (!out)
      return kInvalidArgument;
    *out = nullptr;
    if (FUnknownPrivate::iidEqual(id, IComponentHandler::iid) ||
        FUnknownPrivate::iidEqual(id, FUnknown::iid)) {
      *out = this;
      addRef();
      return kResultOk;
    }
    return kNoInterface;
  }
  tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API performEdit(ParamID, ParamValue) override;
  tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API restartComponent(int32) override;
};
class Effect final : public PluginEffect {
  std::shared_ptr<Module> module_;
  IComponent *component_ = nullptr;
  IAudioProcessor *processor_ = nullptr;
  IEditController *controller_ = nullptr;
  IConnectionPoint *componentConnection_ = nullptr,
                   *controllerConnection_ = nullptr;
  Handler *handler_ = new Handler;
  bool initialized_ = false, controllerInitialized_ = false, active_ = false,
       processing_ = false, mono_ = false;
  std::string id_, error_;
  int inputChannels_ = 2, outputChannels_ = 2;
  int64 sampleTime_ = 0;
  struct Parameter {
    ParameterInfo info{};
    std::atomic<double> input{0}, output{0};
    std::atomic<bool> dirty{false}, outputDirty{false};
  };
  std::unique_ptr<Parameter[]> parameters_;
  int32 parameterCount_ = 0;
  Changes inputChanges_, outputChanges_;
  Events events_;
  std::vector<AudioBusBuffers> inputs_, outputs_;
  std::vector<float> buffers_ = std::vector<float>(6 * MaxFrames);
  float *inputPointers_[2]{buffers_.data(), buffers_.data() + MaxFrames},
      *outputPointers_[2]{buffers_.data() + 2 * MaxFrames,
                          buffers_.data() + 3 * MaxFrames};
  std::atomic<int32> restart_{0}, renderError_{0};
  std::atomic<uint32_t> latency_{0}, rendering_{0};
  std::atomic<bool> suspended_{false};
  float mix_ = 1, target_ = 1;
  void close() {
    if (processor_ && processing_)
      processor_->setProcessing(false);
    if (component_ && active_)
      component_->setActive(false);
    if (controller_)
      controller_->setComponentHandler(nullptr);
    if (componentConnection_ && controllerConnection_) {
      componentConnection_->disconnect(controllerConnection_);
      controllerConnection_->disconnect(componentConnection_);
    }
    release(componentConnection_);
    release(controllerConnection_);
    if (component_ && initialized_)
      component_->terminate();
    if (controller_ && controllerInitialized_)
      controller_->terminate();
    release(controller_);
    release(processor_);
    release(component_);
    processing_ = active_ = initialized_ = controllerInitialized_ = false;
  }
  void restore(const Json &s) {
    if (s.is_null())
      return;
    if (s.at("version") != 1 || s.at("classID") != id_)
      throw std::runtime_error("Mismatched VST3 state");
    auto bytes = unbase64(s.at("component"));
    Stream stream(bytes.data(), bytes.size());
    check(component_->setState(&stream), "Restore processor state");
    stream.rewind();
    if (controller_) {
      controller_->setComponentState(&stream);
      if (s.contains("controller")) {
        auto control = unbase64(s["controller"]);
        Stream c(control.data(), control.size());
        check(controller_->setState(&c), "Restore controller state");
      }
      for (auto &p : s.value("parameters", Json::array())) {
        uint32 id = p.at("id");
        double value = p.at("value");
        if (!std::isfinite(value) || value < 0 || value > 1)
          throw std::runtime_error("Invalid VST3 parameter state");
        controller_->setParamNormalized(id, value);
        edit(id, value);
      }
    }
  }

public:
  Effect(const Json &slot, bool mono, const std::string &path)
      : mono_(mono), id_(slot.at("identifier")) {
    handler_->owner = this;
    try {
      if (slot.at("format") != "vst3")
        throw std::runtime_error("Audio Units are only available on macOS");
      if (path.empty())
        throw std::runtime_error("Install the Windows x64 VST3 effect, scan "
                                 "plugins, then reload this insert");
      module_ = load(path);
      FUID id;
      if (!id.fromString(id_.c_str()))
        throw std::runtime_error("Invalid class ID");
      check(module_->factory->createInstance(
                id.toTUID(), IComponent::iid.toTUID(),
                reinterpret_cast<void **>(&component_)),
            "Create VST3 effect");
      TUID controllerID{};
      bool hasController =
          component_->getControllerClassId(controllerID) == kResultOk;
      component_->setIoMode(kSimple);
      check(component_->initialize(&hostContext), "Initialize VST3");
      initialized_ = true;
      processor_ = query<IAudioProcessor>(component_);
      if (!processor_)
        throw std::runtime_error("Plugin has no audio processor");
      controller_ = query<IEditController>(component_);
      if (!controller_ && hasController) {
        check(module_->factory->createInstance(
                  controllerID, IEditController::iid.toTUID(),
                  reinterpret_cast<void **>(&controller_)),
              "Create controller");
        check(controller_->initialize(&hostContext), "Initialize controller");
        controllerInitialized_ = true;
      }
      if (controller_) {
        controller_->setComponentHandler(handler_);
        componentConnection_ = query<IConnectionPoint>(component_);
        controllerConnection_ = query<IConnectionPoint>(controller_);
        if (componentConnection_ && controllerConnection_) {
          componentConnection_->connect(controllerConnection_);
          controllerConnection_->connect(componentConnection_);
        }
        Stream initial;
        if (component_->getState(&initial) == kResultOk && !initial.failed) {
          initial.rewind();
          controller_->setComponentState(&initial);
        }
        parameterCount_ = controller_->getParameterCount();
        if (parameterCount_ < 0 || parameterCount_ > 32768)
          throw std::runtime_error("Too many plugin parameters");
        parameters_ = std::make_unique<Parameter[]>(parameterCount_);
        for (int32 i = 0; i < parameterCount_; ++i) {
          check(controller_->getParameterInfo(i, parameters_[i].info),
                "Read parameter");
          parameters_[i].input =
              controller_->getParamNormalized(parameters_[i].info.id);
        }
      }
      inputChanges_.prepare(parameterCount_);
      outputChanges_.prepare(parameterCount_);
      restore(slot.value("nativeState", Json()));
      prepare(48000, MaxFrames, 2);
      restart_ = 0;
    } catch (const std::exception &e) {
      error_ = e.what();
      close();
    }
  }
  ~Effect() {
    close();
    handler_->owner = nullptr;
    handler_->release();
  }
  void prepare(double rate, uint32_t frames, uint32_t channels) override {
    if (rate != 48000 || frames > MaxFrames || channels != 2)
      throw std::runtime_error("Unsupported VST3 format");
    check(processor_->canProcessSampleSize(kSample32), "VST3 Float32 support");
    int32 ins = component_->getBusCount(kAudio, kInput),
          outs = component_->getBusCount(kAudio, kOutput);
    if (ins < 1 || outs < 1 || ins > 32 || outs > 32)
      throw std::runtime_error("VST3 must have a main audio input and output");
    std::vector<SpeakerArrangement> input(ins, SpeakerArr::kEmpty),
        output(outs, SpeakerArr::kEmpty);
    bool configured = false;
    for (auto pair :
         mono_ ? std::array<std::pair<int, int>, 3>{{{1, 2}, {1, 1}, {2, 2}}}
               : std::array<std::pair<int, int>, 3>{{{2, 2}, {2, 2}, {2, 2}}}) {
      input[0] = pair.first == 1 ? SpeakerArr::kMono : SpeakerArr::kStereo;
      output[0] = pair.second == 1 ? SpeakerArr::kMono : SpeakerArr::kStereo;
      if (processor_->setBusArrangements(input.data(), ins, output.data(),
                                         outs) == kResultOk) {
        inputChannels_ = pair.first;
        outputChannels_ = pair.second;
        configured = true;
        break;
      }
    }
    if (!configured)
      throw std::runtime_error(
          "Plugin does not support this mono/stereo layout");
    inputs_.resize(ins);
    outputs_.resize(outs);
    ProcessSetup setup{kRealtime, kSample32, int32(frames), rate};
    check(processor_->setupProcessing(setup), "VST3 processing setup");
    for (auto direction : {kInput, kOutput}) {
      for (int32 i = 0; i < (direction == kInput ? ins : outs); ++i) {
        BusInfo info{};
        check(component_->getBusInfo(kAudio, direction, i, info), "VST3 bus");
        if (i == 0 &&
            (info.busType != kMain ||
             info.channelCount !=
                 (direction == kInput ? inputChannels_ : outputChannels_)))
          throw std::runtime_error("Unsupported main bus");
        check(component_->activateBus(kAudio, direction, i, i == 0),
              "Activate VST3 bus");
      }
      for (int32 i = 0; i < component_->getBusCount(kEvent, direction); ++i)
        component_->activateBus(kEvent, direction, i, false);
    }
    inputs_[0].numChannels = inputChannels_;
    inputs_[0].channelBuffers32 = inputPointers_;
    outputs_[0].numChannels = outputChannels_;
    outputs_[0].channelBuffers32 = outputPointers_;
    check(component_->setActive(true), "Activate VST3");
    active_ = true;
    auto n = processor_->setProcessing(true);
    if (n != kResultOk && n != kNotImplemented)
      check(n, "Start VST3");
    processing_ = true;
    latency_ = processor_->getLatencySamples();
  }
  void process(float *const *audio, uint32_t channels,
               uint32_t frames) noexcept override {
    if (channels != 2 || frames > MaxFrames)
      return;
    rendering_.fetch_add(1, std::memory_order_seq_cst);
    bool ready = processor_ && !suspended_.load(std::memory_order_seq_cst);
    for (int c = 0; c < 2; ++c) {
      std::copy_n(audio[c], frames, buffers_.data() + (4 + c) * MaxFrames);
      std::copy_n(audio[c], frames, inputPointers_[c]);
      std::fill_n(outputPointers_[c], frames, 0.f);
    }
    tresult result = kResultFalse;
    if (ready) {
      inputChanges_.clear();
      outputChanges_.clear();
      for (int32 i = 0; i < parameterCount_; ++i)
        if (parameters_[i].dirty.exchange(false)) {
          int32 index = 0;
          auto q =
              inputChanges_.addParameterData(parameters_[i].info.id, index);
          if (q)
            q->addPoint(0, parameters_[i].input.load(), index);
        }
      inputs_[0].silenceFlags = outputs_[0].silenceFlags = 0;
      ProcessContext context{};
      context.sampleRate = 48000;
      context.projectTimeSamples = sampleTime_;
      context.continousTimeSamples = sampleTime_;
      context.state = ProcessContext::kPlaying | ProcessContext::kContTimeValid;
      ProcessData data;
      data.processMode = kRealtime;
      data.symbolicSampleSize = kSample32;
      data.numSamples = frames;
      data.numInputs = int32(inputs_.size());
      data.numOutputs = int32(outputs_.size());
      data.inputs = inputs_.data();
      data.outputs = outputs_.data();
      data.inputParameterChanges = &inputChanges_;
      data.outputParameterChanges = &outputChanges_;
      data.inputEvents = &events_;
      data.outputEvents = &events_;
      data.processContext = &context;
      try {
        result = processor_->process(data);
      } catch (...) {
        result = kInternalError;
      }
      renderError_ = result;
      for (int32 q = 0; q < outputChanges_.getParameterCount(); ++q) {
        auto values = outputChanges_.getParameterData(q);
        ParamValue value = 0;
        int32 offset = 0;
        if (values->getPoint(values->getPointCount() - 1, offset, value) !=
                kResultOk ||
            !std::isfinite(value))
          continue;
        for (int32 i = 0; i < parameterCount_; ++i)
          if (parameters_[i].info.id == values->getParameterId()) {
            parameters_[i].output = value;
            parameters_[i].outputDirty = true;
          }
      }
    }
    sampleTime_ += frames;
    for (uint32_t f = 0; f < frames; ++f) {
      mix_ += std::clamp(target_ - mix_, -1.f / 240, 1.f / 240);
      for (int c = 0; c < 2; ++c) {
        int wc = std::min(c, outputChannels_ - 1);
        float wet = result == kResultOk &&
                            !(outputs_[0].silenceFlags & (uint64(1) << wc))
                        ? outputPointers_[wc][f]
                        : 0;
        if (!std::isfinite(wet))
          wet = 0;
        audio[c][f] =
            buffers_[(4 + c) * MaxFrames + f] * (1 - mix_) + wet * mix_;
      }
    }
    rendering_.fetch_sub(1, std::memory_order_seq_cst);
  }
  void reset() noexcept override {}
  void setBypassed(bool value) noexcept override { target_ = value ? 0 : 1; }
  uint32_t latencyFrames() const noexcept override { return latency_; }
  void queueEdit(uint32_t id, double value) {
    if (!std::isfinite(value) || value < 0 || value > 1)
      throw std::runtime_error("Invalid parameter value");
    for (int32 i = 0; i < parameterCount_; ++i)
      if (parameters_[i].info.id == id &&
          !(parameters_[i].info.flags & ParameterInfo::kIsReadOnly)) {
        parameters_[i].input = value;
        parameters_[i].dirty = true;
        return;
      }
  }
  void edit(uint32_t id, double value) override {
    queueEdit(id, value);
    if (controller_)
      controller_->setParamNormalized(id, value);
  }
  void restart(int32 flags) { restart_.fetch_or(flags); }
  void service() override {
    if (!controller_ || !error_.empty())
      return;
    int flags = restart_.exchange(0);
    if (flags & (kIoChanged | kReloadComponent)) {
      suspended_ = true;
      error_ = "Plugin configuration changed. Reload this insert.";
      return;
    }
    if (flags & kLatencyChanged) {
      suspended_.store(true, std::memory_order_seq_cst);
      if (rendering_.load(std::memory_order_seq_cst) == 0) {
        try {
          processor_->setProcessing(false);
          processing_ = false;
          component_->setActive(false);
          active_ = false;
          check(component_->setActive(true), "Reactivate VST3");
          active_ = true;
          auto result = processor_->setProcessing(true);
          if (result != kResultOk && result != kNotImplemented)
            check(result, "Restart VST3");
          processing_ = true;
          latency_ = processor_->getLatencySamples();
          suspended_ = false;
        } catch (const std::exception &e) {
          error_ = e.what();
        }
      } else
        restart_.fetch_or(kLatencyChanged);
    }
    for (int32 i = 0; i < parameterCount_; ++i) {
      auto &p = parameters_[i];
      if (p.outputDirty.exchange(false) && !p.dirty.load()) {
        controller_->setParamNormalized(p.info.id, p.output.load());
        p.input = p.output.load();
      }
      if (flags & kParamValuesChanged)
        queueEdit(p.info.id, controller_->getParamNormalized(p.info.id));
    }
  }
  Json parameters() override {
    service();
    Json result = Json::array();
    for (int32 i = 0; i < parameterCount_; ++i) {
      auto &p = parameters_[i];
      result.push_back(
          {{"id", p.info.id},
           {"name", text16(p.info.title)},
           {"units", text16(p.info.units)},
           {"value", p.input.load()},
           {"steps", p.info.stepCount},
           {"readOnly", bool(p.info.flags & ParameterInfo::kIsReadOnly)}});
    }
    return result;
  }
  Json snapshot() override {
    if (!component_ || !error_.empty())
      return nullptr;
    // VST3 permits getState on the control thread while Processing. Suspending
    // the renderer here would cause a dropout on every periodic autosave.
    // Read pending edits first: the audio thread may consume them during
    // getState.
    Json pending = Json::array();
    for (int32 i = 0; i < parameterCount_; ++i)
      if (parameters_[i].dirty.load())
        pending.push_back({{"id", parameters_[i].info.id},
                           {"value", parameters_[i].input.load()}});
    Json result;
    Stream component;
    if (component_->getState(&component) == kResultOk && !component.failed) {
      result = {{"version", 1},
                {"classID", id_},
                {"component", base64(component.bytes)},
                {"parameters", std::move(pending)}};
      Stream control;
      if (controller_ && controller_->getState(&control) == kResultOk &&
          !control.failed && !control.bytes.empty())
        result["controller"] = base64(control.bytes);
    }
    return result;
  }
  std::vector<uint8_t> saveState() const override { return {}; }
  void restoreState(const std::vector<uint8_t> &) override {
    throw std::runtime_error("Restore by replacing the prepared insert");
  }
  Json status() const override {
    return {{"available", component_ != nullptr && error_.empty()},
            {"error", error_},
            {"renderError", renderError_.load()},
            {"latencyFrames", latency_.load()}};
  }
};
tresult Handler::performEdit(ParamID id, ParamValue value) {
  try {
    if (owner)
      owner->queueEdit(id, value);
    return kResultOk;
  } catch (...) {
    return kInvalidArgument;
  }
}
tresult Handler::restartComponent(int32 flags) {
  if (owner)
    owner->restart(flags);
  return kResultOk;
}
std::wstring quote(const std::wstring &s) {
  return L"\"" + s + L"\"";
} // Only filesystem paths, which cannot contain quotes.
} // namespace
Json inspectVst(const std::string &path) {
  auto module = load(path);
  Json result = Json::array();
  auto *factory = query<IPluginFactory2>(module->factory);
  if (!factory)
    return result;
  PFactoryInfo vendor{};
  factory->getFactoryInfo(&vendor);
  for (int32 i = 0; i < std::min<int32>(factory->countClasses(), 4096); ++i) {
    PClassInfo2 info{};
    if (factory->getClassInfo2(i, &info) != kResultOk ||
        std::strcmp(info.category, kVstAudioEffectClass))
      continue;
    std::string cats = "|" + std::string(info.subCategories) + "|";
    if (cats.find("|Fx|") == std::string::npos)
      continue;
    result.push_back(
        {{"id", classID(info.cid)},
         {"name", info.name},
         {"manufacturer", info.vendor[0] ? info.vendor : vendor.vendor},
         {"path", path},
         {"format", "vst3"}});
  }
  factory->release();
  return result;
}
Json scanVst() {
  wchar_t executable[32768]{};
  GetModuleFileNameW(nullptr, executable, 32768);
  auto scanner = std::filesystem::path(executable).parent_path() /
                 L"DeskPluginScanner.exe";
  if (!std::filesystem::exists(scanner))
    throw std::runtime_error(
        "DeskPluginScanner.exe is missing beside MixingDesk.exe");
  std::set<std::filesystem::path> paths;
  for (const wchar_t *variable : {L"CommonProgramFiles", L"LOCALAPPDATA"}) {
    wchar_t root[32768]{};
    if (!GetEnvironmentVariableW(variable, root, 32768))
      continue;
    auto p = std::filesystem::path(root);
    p /= std::wstring(variable) == L"LOCALAPPDATA" ? L"Programs\\Common\\VST3"
                                                   : L"VST3";
    std::error_code ec;
    for (std::filesystem::recursive_directory_iterator it(
             p, std::filesystem::directory_options::skip_permission_denied, ec),
         end;
         it != end; it.increment(ec)) {
      if (ec) {
        ec.clear();
        continue;
      }
      if (it->path().extension() == L".vst3") {
        paths.insert(it->path());
        if (it->is_directory())
          it.disable_recursion_pending();
      }
    }
  }
  Json result = Json::array();
  std::set<std::string> seen;
  for (auto &p : paths) {
    wchar_t temp[32768]{}, file[32768]{};
    GetTempPathW(32768, temp);
    if (!GetTempFileNameW(temp, L"mdv", 0, file))
      continue;
    std::wstring command = quote(scanner.wstring()) + L" " +
                           quote(p.wstring()) + L" " + quote(file);
    STARTUPINFOW start{};
    start.cb = sizeof(start);
    PROCESS_INFORMATION process{};
    if (CreateProcessW(scanner.c_str(), command.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &start, &process)) {
      if (WaitForSingleObject(process.hProcess, 15000) != WAIT_OBJECT_0) {
        TerminateProcess(process.hProcess, 1);
        WaitForSingleObject(process.hProcess, 1000);
      }
      DWORD code = 1;
      GetExitCodeProcess(process.hProcess, &code);
      CloseHandle(process.hThread);
      CloseHandle(process.hProcess);
      std::error_code ec;
      auto size = std::filesystem::file_size(file, ec);
      if (!code && !ec && size <= 1024 * 1024) {
        try {
          std::ifstream in{std::filesystem::path(file)};
          auto data = Json::parse(in);
          if (data.is_array())
            for (auto item : data) {
              auto id = item.at("id").get<std::string>();
              if (id.size() == 32 &&
                  id.find_first_not_of("0123456789ABCDEF") ==
                      std::string::npos &&
                  seen.insert(id).second) {
                item["path"] = utf8(p.wstring());
                result.push_back(item);
              }
            }
        } catch (...) {
        }
      }
    }
    DeleteFileW(file);
  }
  return result;
}
namespace {
std::filesystem::path catalogPath() {
  wchar_t path[32768]{};
  if (!GetEnvironmentVariableW(L"LOCALAPPDATA", path, 32768))
    return {};
  return std::filesystem::path(path) / L"Mixing Desk" / L"plugin-catalog.json";
}
} // namespace
PluginRack::PluginRack() {
#ifndef MDW_PLUGIN_TESTS
  try {
    auto path = catalogPath();
    std::error_code ec;
    if (path.empty() ||
        std::filesystem::file_size(path, ec) > 4 * 1024 * 1024 || ec)
      return;
    std::ifstream in(path);
    auto cached = Json::parse(in);
    if (!cached.is_array() || cached.size() > 4096)
      return;
    for (auto &item : cached) {
      auto id = item.at("id").get<std::string>();
      if (id.size() != 32 ||
          id.find_first_not_of("0123456789ABCDEF") != std::string::npos ||
          !item.at("path").is_string())
        return;
    }
    catalog_ = std::move(cached);
  } catch (...) {
  }
#endif
}
Json PluginRack::scan() {
  catalog_ = scanVst();
#ifndef MDW_PLUGIN_TESTS
  auto path = catalogPath();
  if (!path.empty()) {
    std::filesystem::create_directories(path.parent_path());
    auto temp = path;
    temp += L".tmp";
    {
      std::ofstream out(temp);
      out << catalog_.dump();
      if (!out)
        throw std::runtime_error("Could not save plugin catalog");
    }
    if (!MoveFileExW(temp.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
      throw std::runtime_error("Could not replace plugin catalog");
  }
#endif
  return catalog_;
}
void PluginRack::prepare(const Json &session, uint64_t generation) {
  std::set<std::string> alive;
  for (const char *kind : {"strips", "buses"})
    for (auto &owner : session.at(kind)) {
      Json context =
          kind == std::string("strips")
              ? owner.at("source")
              : Json{{"excluded", owner.at("excludedStripID")},
                     {"strips", session.at("strips")},
                     {"monitoringMode", session.at("monitoringMode")}};
      // Gain edits must not recreate bus plugins. Keep only source/audition
      // identity.
      if (kind == std::string("buses")) {
        for (auto &strip : context["strips"]) {
          Json item = {{"id", strip.at("id")},
                       {"source", strip.at("source")},
                       {"role", strip.at("role")}};
          if (owner.at("kind") == "monitor")
            item["solo"] = strip.at("solo");
          strip = item;
        }
      }
      for (auto &slot : owner.value("inserts", Json::array()))
        if (slot.at("format") != "builtin") {
          std::string id = slot.at("id");
          alive.insert(id);
          bool mono = kind == std::string("strips") &&
                      owner.at("source").at("channels").size() == 1;
          std::string signature =
              Json::array(
                  {slot.at("format"), slot.at("identifier"), context, mono})
                  .dump();
          auto found = records_.find(id);
          if (found != records_.end() && found->second.signature == signature)
            continue;
          std::string path;
          for (auto &entry : catalog_)
            if (entry.at("id") == slot.at("identifier")) {
              path = entry.at("path");
              break;
            }
          Json prepared = slot;
          if (found != records_.end()) {
            auto snapshot = found->second.effect->snapshot();
            if (!snapshot.is_null() &&
                snapshot.at("classID") == slot.at("identifier"))
              prepared["nativeState"] = snapshot;
          }
          auto effect = std::make_shared<Effect>(prepared, mono, path);
          if (found != records_.end())
            retired_.push_back({generation, found->second.effect});
          records_[id] = {signature, effect};
        }
    }
  for (auto it = records_.begin(); it != records_.end();)
    if (!alive.count(it->first)) {
      retired_.push_back({generation, it->second.effect});
      it = records_.erase(it);
    } else
      ++it;
}
InsertProcessor *PluginRack::processor(const Json &slot, bool) {
  auto it = records_.find(slot.at("id"));
  return it == records_.end() ? nullptr : it->second.effect.get();
}
void PluginRack::collect(uint64_t generation) {
  std::erase_if(retired_, [&](const auto &r) { return r.first <= generation; });
}
Json PluginRack::status() {
  Json result = Json::array();
  for (auto &[id, r] : records_) {
    r.effect->service();
    auto s = r.effect->status();
    s["id"] = id;
    result.push_back(s);
  }
  return result;
}
Json PluginRack::states() {
  Json result = Json::object();
  for (auto &[id, r] : records_) {
    auto state = r.effect->snapshot();
    if (!state.is_null())
      result[id] = state;
  }
  return result;
}
Json PluginRack::parameters(const std::string &id) {
  return records_.at(id).effect->parameters();
}
void PluginRack::edit(const std::string &id, uint32_t parameter, double value) {
  records_.at(id).effect->edit(parameter, value);
}
void PluginRack::reload(const std::string &id, uint64_t) {
  auto it = records_.find(id);
  if (it != records_.end())
    it->second.signature.clear();
}
} // namespace desk::windows
