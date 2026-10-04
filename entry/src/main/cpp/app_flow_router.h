#pragma once
#include "napi/native_api.h"
#include "../../../../native/patches/app-flow-route.h"
int AppFlowBegin(const AppFlowTuple* tuple, uint64_t* id, void* opaque);
void AppFlowCancel(uint64_t id, void* opaque);
bool AppFlowEnabled();
void RegisterAppFlowRouter(napi_env env, napi_value exports);
