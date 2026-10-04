# Native bridge

`libheyvpn.so` is the C++ N-API bridge. The production path is:

```text
HarmonyOS VPN TUN → libhevsocks5tun.so → local SOCKS → libxray.so
```

CMake builds `napi_init.cpp`, `xray_start_lifecycle.cpp` and `app_flow_router.cpp`, then copies the two rebuilt cores from `prebuilt/arm64-v8a/`. No native binaries are committed; use `scripts/build-public.sh` after preparing the pinned OpenHarmony Go toolchain. See [BUILDING.md](../../../../docs/BUILDING.md) and `native/CORE_LOCK.json`.

Derived native bridge and tun2socks adapter code retains the Hey attribution. The old tun2socks adapter is reference code and is not packaged in the production HAP.
