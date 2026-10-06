#include "VstHost.hpp"
#include <filesystem>
#include <fstream>
#include <objbase.h>
#include <windows.h>
int wmain(int argc, wchar_t **argv) {
  if (argc != 3)
    return 2;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  int code = 0;
  try {
    auto bytes = std::filesystem::path(argv[1]).u8string();
    auto result = desk::windows::inspectVst(std::string(
        reinterpret_cast<const char *>(bytes.data()), bytes.size()));
    std::ofstream out{std::filesystem::path(argv[2])};
    out << result.dump();
    if (!out)
      code = 1;
  } catch (...) {
    code = 1;
  }
  CoUninitialize();
  return code;
}
