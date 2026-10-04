/**
 * 内置 Xray 内核（xtls/xray-core）的版本号 —— 即 `core.Version()` 的返回值。
 *
 * 此常量在重新编译 libxray.so 时由 scripts/build_libxray_ohos.sh 从所锁定的
 * xtls/xray-core 源码（core/core.go 的 Version_x/y/z 常量）自动写入，
 * 与 prebuilt/arm64-v8a/libxray.so 保持同步——请勿手动修改。
 */
export const BUNDLED_XRAY_VERSION: string = '25.8.3';

/** Debug HAP only. Release must leave this false so access logs are not written. */
export const DEBUG_ACCESS: boolean = false;
