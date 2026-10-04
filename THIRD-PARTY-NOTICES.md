# Third-Party Notices

穿山甲整体沿用 GPL-3.0-or-later，许可证全文见 `LICENSE`。第三方文件保留各自原有署名和许可；本仓库发布源码与重建补丁，不分发预编译内核或 Geo 数据文件。

## Hey — GPL-3.0

- 上游：https://github.com/popsiclelmlm/Hey
- 原始参考基线：v1.3.4。
- 使用/改编：N-API 原生桥、VPN 生命周期、tun2socks 适配器、分享链接及订阅解析器、OpenHarmony 交叉编译实现。
- 移植文件包括 `entry/src/main/ets/core/ShareLinkParser.ets`、`Encoding.ets`、`IdnUrl.ets`、`NodeDedupe.ets`、`SubscriptionParser.ets` 和 `entry/src/main/ets/services/SubscriptionManager.ets`。
- 解析器文件中的原有作者注释保留；本项目对去重、KCP、订阅和路由行为进行了修改。
- 原生构建与转发以本仓库 `native/CORE_LOCK.json`、补丁和 `docs/BUILDING.md` 为准。

## Xray-core — MPL-2.0

- 上游：https://github.com/XTLS/Xray-core
- 当前版本：`v1.250803.0`；由锁定的 libXray 源码引入。
- 补丁包括 HarmonyOS socket protect 的失败关闭行为。

## libXray — MIT

- 上游：https://github.com/XTLS/libXray
- 当前提交：`20d70a98a1eef5227252894fa8e08c9e52a67ad6`。
- 通过 OpenHarmony Go fork 构建，提供 N-API 桥消费的 CGo 导出；补丁和构建实现位于 `native/patches/` 与 `scripts/build_libxray_ohos.sh`。

## hev-socks5-tunnel — MIT

- 上游：https://github.com/heiher/hev-socks5-tunnel
- 当前版本：`2.17.1`，提交前缀 `9a06bc6`。
- 补丁包括事件等待、UDP 计数、逐流路由和 TUN 进度。
- 构建时按上游版本获取子模块；各子模块沿用其许可证。

## tun2socks — MIT

- 上游：https://github.com/xjasonlyu/tun2socks
- 保留适配器和历史构建代码作为参考；不随本仓库发布其二进制，生产 HAP 使用 HEV。

## OpenHarmony Go toolchain

- 上游：https://gitcode.com/openharmony-sig/ohos_golang_go
- 工具链提交：`302a5306b6fad2f47196360b82561d1db1f954cf`。
- 工具链由使用者另行获取和构建，沿用 Go 及该上游的许可声明。

## Geo data

- 来源：https://github.com/v2fly/geoip 与 https://github.com/v2fly/domain-list-community
- 数据文件不在本仓库中。`native/GEO_LOCK.json` 保存版本、下载地址和校验和，`scripts/restore_geo.py` 负责按需恢复。
- 下载/再分发数据时需遵守上游数据及其数据来源的许可，包括相应 GeoLite2 数据条款。
