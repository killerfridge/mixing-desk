#include "ClockQueue.hpp"
#include "Host.hpp"
#include "VstHost.hpp"
#include "WindowsAudioCompat.hpp"
#include <appmodel.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <propkeydef.h>
#include <set>
#include <thread>
#include <tlhelp32.h>
#include <windows.h>
#include <wrl/client.h>

// Microsoft's SDK requires DEFINE_PROPERTYKEY from propkeydef.h first.
// MinGW includes that dependency itself, so cross-builds do not catch this.
#include <functiondiscoverykeys_devpkey.h>

namespace desk::windows {
using Microsoft::WRL::ComPtr;
namespace {
void check(HRESULT code, const char *what) {
  if (FAILED(code))
    throw std::runtime_error(std::string(what) + " (HRESULT " +
                             std::to_string(uint32_t(code)) + ")");
}
std::wstring wide(const std::string &s) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              int(s.size()), nullptr, 0);
  std::wstring out(n, 0);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()),
                      out.data(), n);
  return out;
}
std::string utf8(const wchar_t *s) {
  int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
  std::string out(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, s, -1, out.data(), n, nullptr, nullptr);
  if (n)
    out.pop_back();
  return out;
}
struct Event {
  HANDLE value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  ~Event() {
    if (value)
      CloseHandle(value);
  }
  operator HANDLE() const { return value; }
};
struct ComScope {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  ~ComScope() {
    if (SUCCEEDED(hr))
      CoUninitialize();
  }
};
ComPtr<IMMDeviceEnumerator> enumerator() {
  ComPtr<IMMDeviceEnumerator> e;
  check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                         IID_PPV_ARGS(&e)),
        "Enumerate audio devices");
  return e;
}
std::string deviceID(IMMDevice *d) {
  LPWSTR id = nullptr;
  check(d->GetId(&id), "Read endpoint ID");
  std::string s = "win:" + utf8(id);
  CoTaskMemFree(id);
  return s;
}
std::string deviceName(IMMDevice *d) {
  ComPtr<IPropertyStore> store;
  check(d->OpenPropertyStore(STGM_READ, &store), "Read endpoint properties");
  PROPVARIANT value;
  PropVariantInit(&value);
  auto hr = store->GetValue(PKEY_Device_FriendlyName, &value);
  std::string name = SUCCEEDED(hr) && value.vt == VT_LPWSTR
                         ? utf8(value.pwszVal)
                         : "Audio device";
  PropVariantClear(&value);
  return name;
}
std::string processKey(DWORD pid, std::string *name = nullptr) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process)
    return {};
  wchar_t path[32768]{};
  DWORD length = 32768;
  if (!QueryFullProcessImageNameW(process, 0, path, &length)) {
    CloseHandle(process);
    return {};
  }
  if (name) {
    std::wstring p(path);
    auto slash = p.find_last_of(L"\\/");
    *name = utf8(p.substr(slash == std::wstring::npos ? 0 : slash + 1).c_str());
  }
  wchar_t app[32768]{};
  UINT32 count = 32768;
  LONG code = GetApplicationUserModelId(process, &count, app);
  CloseHandle(process);
  if (code == ERROR_SUCCESS)
    return "win:app:" + utf8(app);
  CharLowerBuffW(path, length);
  return "win:exe:" + utf8(path);
}
Json applicationList() {
  auto e = enumerator();
  ComPtr<IMMDeviceCollection> devices;
  check(e->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices),
        "Enumerate playback endpoints");
  UINT count = 0;
  devices->GetCount(&count);
  std::map<std::string, Json> apps;
  std::set<DWORD> pids;
  for (UINT i = 0; i < count; ++i) {
    ComPtr<IMMDevice> d;
    if (FAILED(devices->Item(i, &d)))
      continue;
    ComPtr<IAudioSessionManager2> manager;
    if (FAILED(d->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                           reinterpret_cast<void **>(manager.GetAddressOf()))))
      continue;
    ComPtr<IAudioSessionEnumerator> sessions;
    if (FAILED(manager->GetSessionEnumerator(&sessions)))
      continue;
    int n = 0;
    sessions->GetCount(&n);
    for (int j = 0; j < n; ++j) {
      ComPtr<IAudioSessionControl> control;
      if (FAILED(sessions->GetSession(j, &control)))
        continue;
      ComPtr<IAudioSessionControl2> c;
      if (FAILED(control.As(&c)))
        continue;
      DWORD pid = 0;
      c->GetProcessId(&pid);
      if (!pid || pid == GetCurrentProcessId() || !pids.insert(pid).second)
        continue;
      std::string name;
      auto key = processKey(pid, &name);
      if (key.empty())
        continue;
      auto &app = apps[key];
      if (app.is_null())
        app = {{"id", key}, {"name", name}, {"processIDs", Json::array()}};
      app["processIDs"].push_back(pid);
    }
  }
  // Remove child PIDs already covered by another captured root.
  std::map<DWORD, DWORD> parents;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot != INVALID_HANDLE_VALUE) {
    PROCESSENTRY32W p{};
    p.dwSize = sizeof(p);
    if (Process32FirstW(snapshot, &p))
      do {
        parents[p.th32ProcessID] = p.th32ParentProcessID;
      } while (Process32NextW(snapshot, &p));
    CloseHandle(snapshot);
  }
  Json out = Json::array();
  for (auto &[key, app] : apps) {
    std::set<DWORD> group;
    for (auto &p : app["processIDs"])
      group.insert(p.get<DWORD>());
    Json roots = Json::array();
    for (auto pid : group) {
      DWORD parent = parents[pid];
      std::set<DWORD> seen;
      bool covered = false;
      while (parent && seen.insert(parent).second) {
        if (group.count(parent)) {
          covered = true;
          break;
        }
        parent = parents[parent];
      }
      if (!covered)
        roots.push_back(pid);
    }
    app["processIDs"] = roots;
    out.push_back(app);
  }
  return out;
}
class Completion final : public IActivateAudioInterfaceCompletionHandler,
                         public IAgileObject {
  std::atomic<ULONG> refs{1};

public:
  Event done;
  HRESULT result = E_PENDING;
  ComPtr<IAudioClient> client;
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
  ULONG STDMETHODCALLTYPE Release() override {
    auto n = --refs;
    if (!n)
      delete this;
    return n;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **out) override {
    if (!out)
      return E_POINTER;
    *out = nullptr;
    if (id == __uuidof(IUnknown) ||
        id == __uuidof(IActivateAudioInterfaceCompletionHandler))
      *out = static_cast<IActivateAudioInterfaceCompletionHandler *>(this);
    else if (id == __uuidof(IAgileObject))
      *out = static_cast<IAgileObject *>(this);
    else
      return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE
  ActivateCompleted(IActivateAudioInterfaceAsyncOperation *operation) override {
    ComPtr<IUnknown> unknown;
    HRESULT activation = E_FAIL;
    result = operation->GetActivateResult(&activation, &unknown);
    if (SUCCEEDED(result))
      result = activation;
    if (SUCCEEDED(result))
      result = unknown.As(&client);
    SetEvent(done);
    return S_OK;
  }
};
ComPtr<IAudioClient> applicationClient(DWORD pid) {
  AUDIOCLIENT_ACTIVATION_PARAMS params{};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.TargetProcessId = pid;
  params.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT value{};
  value.vt = VT_BLOB;
  value.blob.cbSize = sizeof(params);
  value.blob.pBlobData = reinterpret_cast<BYTE *>(&params);
  ComPtr<Completion> callback;
  callback.Attach(new Completion);
  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  // Try the capability on Windows 10 too; activation reports availability.
  constexpr auto captureError =
      "Application capture could not start; restart the source app or route "
      "its audio through a virtual-cable input";
  check(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                                    __uuidof(IAudioClient), &value,
                                    callback.Get(), &operation),
        captureError);
  if (WaitForSingleObject(callback->done, 10000) != WAIT_OBJECT_0)
    throw std::runtime_error("Application capture timed out");
  check(callback->result, captureError);
  return callback->client;
}
struct Endpoint {
  std::string key;
  int offset = 0, channels = 2;
  bool input = false, master = false, application = false;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  ComPtr<IAudioRenderClient> render;
  UINT32 capacity = 0;
  std::unique_ptr<ClockQueue> queue;
  std::vector<float> scratch;
  std::atomic<uint64_t> faults{0}, underruns{0}, overruns{0};
  std::atomic<double> correction{0};
  UINT32 periodFrames = 0;
  double latencyMs = 0;
  Endpoint(const std::string &id, bool captureInput, bool primary, int target,
           DWORD pid = 0)
      : key(id), input(captureInput), master(primary), application(pid != 0) {
    DWORD channelMask =
        3; // Stereo process loopback; hardware uses its endpoint layout.
    if (pid)
      client = applicationClient(pid);
    else {
      if (id.rfind("win:", 0) != 0)
        throw std::runtime_error("This device belongs to another platform");
      auto e = enumerator();
      ComPtr<IMMDevice> device;
      check(e->GetDevice(wide(id.substr(4)).c_str(), &device),
            "Open selected audio device");
      check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                             reinterpret_cast<void **>(client.GetAddressOf())),
            "Activate selected audio device");
      WAVEFORMATEX *mix = nullptr;
      check(client->GetMixFormat(&mix), "Read endpoint format");
      channels = mix->nChannels;
      channelMask = channels == 1 ? 4 : channels == 2 ? 3 : 0;
      if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
          mix->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX))
        channelMask =
            reinterpret_cast<WAVEFORMATEXTENSIBLE *>(mix)->dwChannelMask;
      CoTaskMemFree(mix);
    }
    if (channels < 1 || channels > 64)
      throw std::runtime_error("Endpoint must provide 1–64 channels");
    WAVEFORMATEXTENSIBLE extended{};
    auto &format = extended.Format;
    format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    format.nChannels = WORD(channels);
    format.nSamplesPerSec = 48000;
    format.wBitsPerSample = 32;
    format.nBlockAlign = WORD(channels * 4);
    format.nAvgBytesPerSec = 48000 * format.nBlockAlign;
    if (!application) {
      format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
      format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
      extended.Samples.wValidBitsPerSample = 32;
      extended.dwChannelMask = channelMask;
      // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, expressed without an extra GUID
      // import.
      extended.SubFormat = {
          3, 0, 0x0010, {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}};
    }
    DWORD flags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                  AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    if (primary)
      flags |= AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    if (pid)
      flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags,
                             application
                                 ? 0
                                 : REFERENCE_TIME(std::max(target, 480)) *
                                       10000000 / 48000,
                             0, &format, nullptr),
          "Initialize 48 kHz shared audio");
    check(client->GetBufferSize(&capacity), "Read endpoint buffer size");
    REFERENCE_TIME period = 0, minimum = 0;
    if (SUCCEEDED(client->GetDevicePeriod(&period, &minimum)))
      periodFrames = UINT32(period * 48000 / 10000000);
    REFERENCE_TIME latency = 0;
    if (SUCCEEDED(client->GetStreamLatency(&latency)))
      latencyMs = double(latency) / 10000;
    if (input)
      check(client->GetService(IID_PPV_ARGS(&capture)), "Open capture stream");
    else
      check(client->GetService(IID_PPV_ARGS(&render)), "Open playback stream");
    scratch.resize(size_t(std::max<UINT32>(capacity, MaxFrames)) * channels);
    if (!master)
      queue =
          std::make_unique<ClockQueue>(channels, std::max(target * 3, 1440));
  }
  void capturePackets() {
    UINT32 n = 0;
    check(capture->GetNextPacketSize(&n), "Read capture packet");
    while (n) {
      BYTE *data = nullptr;
      DWORD flags = 0;
      check(capture->GetBuffer(&data, &n, &flags, nullptr, nullptr),
            "Read captured audio");
      if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) {
        queue->reset();
        ++faults;
      }
      queue->push(flags & AUDCLNT_BUFFERFLAGS_SILENT
                      ? nullptr
                      : reinterpret_cast<float *>(data),
                  int(n));
      check(capture->ReleaseBuffer(n), "Release capture packet");
      check(capture->GetNextPacketSize(&n), "Read next capture packet");
    }
  }
};
class WasapiHost final : public AudioHost {
  ComScope com_;
  std::unique_ptr<Engine> engine_ = std::make_unique<Engine>();
  PluginRack rack_;
  Json session_, offline_ = Json::array();
  std::vector<std::unique_ptr<Endpoint>> endpoints_;
  Endpoint *master_ = nullptr;
  Bindings inputs_, outputs_;
  int inputCount_ = 0, outputCount_ = 0;
  Event stopEvent_, renderEvent_;
  std::thread thread_;
  std::atomic<bool> running_{false}, outputProtection_{true};
  std::atomic<uint32_t> failure_{0};
  std::atomic<double> load_{0};
  std::atomic<uint64_t> cycles_{0};
  std::vector<float> input_ = std::vector<float>(MaxChannels * MaxFrames),
                     output_ = std::vector<float>(MaxChannels * MaxFrames);
  std::array<const float *, MaxChannels> inputPointers_{};
  std::array<float *, MaxChannels> outputPointers_{};
  std::unique_ptr<Configuration> configuration_;
  std::string topology_;
  std::string topology(const Json &s) {
    Json j = {{"monitor", s.at("monitorDeviceUID")},
              {"buffer", s.at("bufferFrames")},
              {"sources", Json::array()},
              {"outputs", Json::array()}};
    for (auto &strip : s.at("strips"))
      j["sources"].push_back(strip.at("source"));
    std::set<std::string> outputs;
    for (auto &route : s.at("routes"))
      outputs.insert(route.at("destinationUID"));
    for (auto &id : outputs)
      j["outputs"].push_back(id);
    return j.dump();
  }
  void publish(const Json &s) {
    rack_.prepare(s, engine_->publishedGeneration() + 1);
    auto config =
        compileSession(s, inputs_, outputs_, [&](auto &slot, bool mono) {
          return rack_.processor(slot, mono);
        });
    std::string error;
    if (!engine_->publish(*config, error))
      throw std::runtime_error(error);
    if (!running_)
      engine_->activateStopped();
    configuration_ = std::move(config);
    outputProtection_ = configuration_->outputProtectionEnabled;
    session_ = s;
    rack_.collect(engine_->completedGeneration());
  }
  void run() {
    ComScope com;
    DWORD index = 0;
    HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &index);
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    HANDLE events[] = {stopEvent_, renderEvent_};
    try {
      for (auto &e : endpoints_)
        check(e->client->Start(), "Start audio endpoint");
      while (running_) {
        DWORD wait = WaitForMultipleObjects(2, events, FALSE, 2000);
        if (wait == WAIT_OBJECT_0)
          break;
        if (wait != WAIT_OBJECT_0 + 1)
          throw std::runtime_error("Audio clock stopped");
        LARGE_INTEGER begin, end;
        QueryPerformanceCounter(&begin);
        for (auto &e : endpoints_)
          if (e->input)
            e->capturePackets();
        UINT32 padding = 0;
        check(master_->client->GetCurrentPadding(&padding),
              "Read monitor clock");
        UINT32 available = master_->capacity - padding;
        while (available) {
          int frames = int(std::min<UINT32>(available, MaxFrames));
          for (int c = 0; c < inputCount_; ++c)
            std::fill_n(input_.data() + c * MaxFrames, frames, 0.f);
          for (auto &e : endpoints_)
            if (e->input) {
              e->queue->pull(e->scratch.data(), frames);
              for (int c = 0; c < e->channels; ++c)
                for (int f = 0; f < frames; ++f)
                  input_[size_t(e->offset + c) * MaxFrames + f] +=
                      e->scratch[size_t(f) * e->channels + c];
            }
          engine_->render(inputPointers_.data(), inputCount_,
                          outputPointers_.data(), outputCount_, frames);
          for (auto &e : endpoints_)
            if (!e->input) {
              for (int f = 0; f < frames; ++f)
                for (int c = 0; c < e->channels; ++c)
                  e->scratch[size_t(f) * e->channels + c] =
                      output_[size_t(e->offset + c) * MaxFrames + f];
              if (e->master) {
                BYTE *buffer = nullptr;
                check(e->render->GetBuffer(frames, &buffer),
                      "Get monitor buffer");
                std::memcpy(buffer, e->scratch.data(),
                            size_t(frames) * e->channels * sizeof(float));
                check(e->render->ReleaseBuffer(frames, 0),
                      "Write monitor audio");
              } else
                e->queue->push(e->scratch.data(), frames);
            }
          available -= frames;
          ++cycles_;
        }
        for (auto &e : endpoints_)
          if (!e->input && !e->master) {
            UINT32 padding = 0;
            check(e->client->GetCurrentPadding(&padding), "Read output clock");
            UINT32 available = e->capacity - padding;
            while (available) {
              int frames = int(std::min<UINT32>(available, MaxFrames));
              e->queue->pull(e->scratch.data(), frames);
              BYTE *buffer = nullptr;
              check(e->render->GetBuffer(frames, &buffer), "Get output buffer");
              auto *samples = reinterpret_cast<float *>(buffer);
              bool protection =
                  outputProtection_.load(std::memory_order_relaxed);
              for (size_t i = 0; i < size_t(frames) * e->channels; ++i) {
                float x = e->scratch[i];
                // Clock correction can introduce new sample peaks.
                samples[i] = std::isfinite(x)
                                 ? (protection ? std::clamp(x, -.8912509381f,
                                                            .8912509381f)
                                               : x)
                                 : 0;
              }
              check(e->render->ReleaseBuffer(frames, 0), "Write output audio");
              available -= frames;
            }
          }
        for (auto &e : endpoints_)
          if (e->queue) {
            e->underruns = e->queue->underruns;
            e->overruns = e->queue->overruns;
            e->correction = e->queue->correction();
          }
        QueryPerformanceCounter(&end);
        load_ = double(end.QuadPart - begin.QuadPart) / frequency.QuadPart /
                (double(master_->capacity) / 48000);
      }
    } catch (...) {
      failure_ = 1;
    }
    running_ = false;
    for (auto &e : endpoints_)
      e->client->Stop();
    if (task)
      AvRevertMmThreadCharacteristics(task);
  }

public:
  WasapiHost() {
    if (FAILED(com_.hr) && com_.hr != RPC_E_CHANGED_MODE)
      check(com_.hr, "Initialize Windows audio");
    for (int i = 0; i < MaxChannels; ++i) {
      inputPointers_[i] = input_.data() + i * MaxFrames;
      outputPointers_[i] = output_.data() + i * MaxFrames;
    }
  }
  ~WasapiHost() { stop(); }
  Json devices() override {
    auto e = enumerator();
    ComPtr<IMMDeviceCollection> all;
    check(e->EnumAudioEndpoints(eAll, DEVICE_STATE_ACTIVE, &all),
          "List audio devices");
    UINT count = 0;
    all->GetCount(&count);
    Json out = Json::array();
    for (UINT i = 0; i < count; ++i) {
      try {
        ComPtr<IMMDevice> device;
        check(all->Item(i, &device), "Read audio device");
        ComPtr<IMMEndpoint> endpoint;
        check(device.As(&endpoint), "Read endpoint direction");
        EDataFlow flow;
        endpoint->GetDataFlow(&flow);
        ComPtr<IAudioClient> client;
        check(
            device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                             reinterpret_cast<void **>(client.GetAddressOf())),
            "Read endpoint capabilities");
        WAVEFORMATEX *mix = nullptr;
        check(client->GetMixFormat(&mix), "Read endpoint mix format");
        Json d = {{"uid", deviceID(device.Get())},
                  {"name", deviceName(device.Get())},
                  {"inputChannels", flow == eCapture ? mix->nChannels : 0},
                  {"outputChannels", flow == eRender ? mix->nChannels : 0},
                  {"sampleRate", mix->nSamplesPerSec}};
        CoTaskMemFree(mix);
        out.push_back(d);
      } catch (...) {
      }
    }
    return out;
  }
  Json applications() override { return applicationList(); }
  void start(const Json &s) override {
    validateSession(s);
    stop();
    Json prepared = s;
    auto states = rack_.states();
    for (const char *kind : {"strips", "buses"})
      for (auto &owner : prepared.at(kind))
        if (owner.contains("inserts"))
          for (auto &slot : owner["inserts"]) {
            std::string id = slot.at("id");
            if (slot.at("format") == "vst3" && states.contains(id) &&
                states[id].at("classID") == slot.at("identifier"))
              slot["nativeState"] = states[id];
          }
    engine_->reset();
    rack_.clear();
    endpoints_.clear();
    inputs_.clear();
    outputs_.clear();
    inputCount_ = outputCount_ = 0;
    master_ = nullptr;
    offline_ = Json::array();
    failure_ = 0;
    cycles_ = 0;
    ResetEvent(stopEvent_);
    ResetEvent(renderEvent_);
    try {
      std::string monitor = s.at("monitorDeviceUID");
      if (monitor.empty())
        throw std::runtime_error(
            "Choose an available headphone or monitor output");
      int target = s.at("bufferFrames");
      auto addOutput = [&](const std::string &key, bool master) {
        auto e = std::make_unique<Endpoint>(key, false, master, target);
        if (outputCount_ + e->channels > MaxChannels)
          throw std::runtime_error("Output capacity exceeded");
        e->offset = outputCount_;
        outputs_[key] = {outputCount_, e->channels};
        outputCount_ += e->channels;
        if (master) {
          master_ = e.get();
          check(e->client->SetEventHandle(renderEvent_),
                "Set monitor clock event");
        }
        endpoints_.push_back(std::move(e));
      };
      addOutput(monitor, true);
      for (auto &r : s.at("routes")) {
        std::string key = r.at("destinationUID");
        if (!outputs_.count(key) && !key.empty()) {
          try {
            addOutput(key, false);
          } catch (const std::exception &e) {
            offline_.push_back({{"id", key}, {"error", e.what()}});
          }
        }
      }
      auto apps = applicationList();
      std::set<std::string> attempted;
      for (auto &strip : s.at("strips")) {
        auto &source = strip.at("source");
        bool app = source.at("kind") == "application";
        std::string key = app ? source.at("bundleID") : source.at("deviceUID");
        if (key.empty() || !attempted.insert(key).second)
          continue;
        try {
          std::vector<DWORD> pids;
          if (app) {
            for (auto &a : apps)
              if (a.at("id") == key)
                for (auto &pid : a.at("processIDs"))
                  pids.push_back(pid);
            if (pids.empty())
              throw std::runtime_error("Application is offline; restart audio "
                                       "after it begins playing");
          } else
            pids.push_back(0);
          int count = 0;
          for (auto pid : pids) {
            auto e = std::make_unique<Endpoint>(key, true, false, target, pid);
            if (inputCount_ + e->channels > MaxChannels)
              throw std::runtime_error("Input capacity exceeded");
            if (count && count != e->channels)
              throw std::runtime_error("Application channel layout changed");
            count = e->channels;
            e->offset = inputCount_;
            endpoints_.push_back(std::move(e));
          }
          inputs_[key] = {inputCount_, count};
          inputCount_ += count;
        } catch (const std::exception &e) {
          std::erase_if(endpoints_, [&](auto &endpoint) {
            return endpoint->input && endpoint->key == key;
          });
          offline_.push_back({{"id", key}, {"error", e.what()}});
        }
      }
      publish(prepared);
      topology_ = topology(s);
      running_ = true;
      thread_ = std::thread([this] { run(); });
    } catch (...) {
      stop();
      throw;
    }
  }
  void update(const Json &s) override {
    validateSession(s);
    if (running_ && topology(s) != topology_) {
      start(s);
      return;
    }
    publish(s);
  }
  void loadSession(const Json &s) override {
    validateSession(s);
    stop();
    rack_.clear();
    engine_->reset();
    publish(s);
  }
  void stop() override {
    running_ = false;
    SetEvent(stopEvent_);
    if (thread_.joinable())
      thread_.join();
    engine_->activateStopped();
    rack_.collect(engine_->completedGeneration());
  }
  Json status() override {
    Json meters = Json::array(), buses = Json::array(), outputs = Json::array(),
         clocks = Json::array();
    if (!session_.is_null()) {
      for (auto &s : session_["strips"])
        meters.push_back(meterJson(
            engine_->stripMeterForOwner(identity(s.at("id"))), s.at("id")));
      for (auto &b : session_["buses"])
        buses.push_back(meterJson(
            engine_->busMeterForOwner(identity(b.at("id"))), b.at("id")));
    }
    if (configuration_)
      for (int i = 0; i < configuration_->protectionGroupCount; ++i) {
        auto &g = configuration_->protectionGroups[i];
        auto meter = meterJson(engine_->outputMeterForGroup(g.identity),
                               std::to_string(g.identity));
        meter["destinations"] = Json::array();
        for (const auto &[uid, binding] : outputs_) {
          Json channels = Json::array();
          for (int c = g.firstChannel; c >= 0;
               c = configuration_->nextProtectionChannel[c])
            if (c >= binding.offset && c < binding.offset + binding.channels)
              channels.push_back(c - binding.offset);
          if (!channels.empty())
            meter["destinations"].push_back({{"uid", uid}, {"channels", channels}});
        }
        outputs.push_back(std::move(meter));
      }
    // Render publishes queue diagnostics through atomics.
    for (auto &e : endpoints_)
      clocks.push_back({{"id", e->key},
                        {"master", e->master},
                        {"periodFrames", e->periodFrames},
                        {"bufferFrames", e->capacity},
                        {"latencyMs", e->latencyMs},
                        {"discontinuities", e->faults.load()},
                        {"underruns", e->underruns.load()},
                        {"overruns", e->overruns.load()},
                        {"driftPPM", e->correction.load() * 1000000}});
    rack_.collect(engine_->completedGeneration());
    return {
        {"running", running_.load()},
        {"error",
         failure_.load()
             ? "An audio endpoint stopped or was disconnected. Check devices "
               "and explicitly restart audio."
             : ""},
        {"load", load_.load()},
        {"cycles", cycles_.load()},
        {"strips", meters},
        {"buses", buses},
        {"outputs", outputs},
        {"clocks", clocks},
        {"offline", offline_},
        {"plugins", rack_.status()},
        {"protectionLatencyMs", 2}};
  }
  Json plugins(const std::string &op, const Json &args) override {
    if (op == "scanPlugins")
      return rack_.scan();
    if (op == "pluginStates")
      return rack_.states();
    if (op == "pluginParameters")
      return rack_.parameters(args.at("id"));
    if (op == "setParameter") {
      rack_.edit(args.at("id"), args.at("parameter"), args.at("value"));
      return nullptr;
    }
    if (op == "reloadPlugin") {
      rack_.reload(args.at("id"), engine_->publishedGeneration() + 1);
      if (!session_.is_null())
        publish(session_);
      return nullptr;
    }
    throw std::runtime_error("Unknown plugin operation");
  }
  void resetMeter(const std::string &id, bool bus) override {
    if (id.empty())
      engine_->resetAllMeters();
    else
      engine_->resetMeter(identity(id), bus);
    if (!running_)
      engine_->serviceMeterResetsStopped();
  }
};
} // namespace
std::unique_ptr<AudioHost> makeWindowsHost() {
  return std::make_unique<WasapiHost>();
}
} // namespace desk::windows
