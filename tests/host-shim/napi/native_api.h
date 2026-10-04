#pragma once
// Host-only header adaptation. Real HarmonyOS builds use the SDK's header.
#include <node_api.h>
#ifndef EXTERN_C_START
#define EXTERN_C_START extern "C" {
#define EXTERN_C_END }
#endif
