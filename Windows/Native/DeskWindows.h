#pragma once
#include <stdint.h>
#if defined(_WIN32)
#define MDW_API __declspec(dllexport)
#else
#define MDW_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
// ABI 1. UTF-8 JSON control messages; never called from an audio callback.
// A host belongs to one serialized control thread. Returned strings are owned
// by the caller and must be freed with mdw_free, including error responses.
// Responses: {"ok":true,"value":...} or {"ok":false,"error":"..."}.
MDW_API uint32_t mdw_abi_version(void);
MDW_API void *mdw_create(void);
MDW_API void mdw_destroy(void *host);
MDW_API char *mdw_request(void *host, const char *operation, const char *json);
MDW_API void mdw_free(char *response);
#ifdef __cplusplus
}
#endif
