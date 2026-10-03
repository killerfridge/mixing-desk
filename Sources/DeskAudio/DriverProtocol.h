#pragma once
#define MD_DRIVER_BUNDLE_ID "local.mixingdesk.driver"
#define MD_DRIVER_CONFIG_SELECTOR 'mdcf'
#define MD_DRIVER_PROTOCOL_VERSION 1
#define MD_DRIVER_BUILD 2
#define MD_DRIVER_MAX_DEVICES 16
#define MD_DRIVER_MAX_CHANNELS 64
#define MD_DRIVER_RATE 48000.0
#define MD_DRIVER_LATENCY 256
// AudioServerPlugIn.h requires at least 10,923 frames between zero timestamps.
// This clock period is independent of the application's IO buffer size.
#define MD_DRIVER_TIMESTAMP_PERIOD 16384
#define MD_DRIVER_STORAGE_KEY "MixingDeskDevicesV1"
// CFDictionary property: {version:1, devices:[{uid, name, channels, bridgeUID, clients}]}.
// Setter accepts {version:1, operation:"create"|"rename"|"delete", uid, name?, channels?}.
// All configuration traffic is on non-real-time control threads.
