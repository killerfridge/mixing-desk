#pragma once
#include "DriverProtocol.h"

namespace desk {
// Separate the file installed on disk from the code currently loaded by HAL.
enum class DriverAvailability { missing, restartRequired, incompatible, ready };
inline DriverAvailability driverAvailability(bool installed, int installedBuild,
                                             bool loaded, int loadedBuild, int protocol) {
    if (!installed) return loaded ? DriverAvailability::restartRequired : DriverAvailability::missing;
    if (installedBuild < MD_DRIVER_BUILD) return DriverAvailability::incompatible;
    if (!loaded) return DriverAvailability::restartRequired;
    if (loadedBuild <= 0 || protocol != MD_DRIVER_PROTOCOL_VERSION) return DriverAvailability::incompatible;
    if (installedBuild != loadedBuild) return DriverAvailability::restartRequired;
    return DriverAvailability::ready;
}
}
