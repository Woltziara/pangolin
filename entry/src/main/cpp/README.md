# Native bridge

`libheyvpn.so` is the C++ N-API bridge. The production path is:

```text
HarmonyOS VPN TUN → libhevsocks5tun.so → local SOCKS → libxray.so
```

CMake builds `napi_init.cpp`, `xray_start_lifecycle.cpp` and `app_flow_router.cpp`, then copies the two rebuilt cores from `prebuilt/arm64-v8a/`. No native binaries are committed; use `scripts/build.sh` after preparing the pinned OpenHarmony Go toolchain. See [BUILDING.md](../../../../docs/BUILDING.md) and `native/CORE_LOCK.json`.

The derived bridge retains its Hey attribution. The active bridge supports only the pinned Xray CGo ABI and HEV, with 16 app-facing N-API methods. ABI types live in `types/libheyvpn/Index.d.ts` and are reused by ArkTS.
