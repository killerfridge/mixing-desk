#include <unistd.h>
// Simulates a vendor module terminating its scanner. The mixer/test parent
// must remain alive and continue discovering the working fixture.
extern "C" bool bundleEntry(void*) { return true; }
extern "C" bool bundleExit() { return true; }
extern "C" void* GetPluginFactory() { _exit(42); }
