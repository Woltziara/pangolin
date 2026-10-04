# 构建穿山甲

## 1. SDK 与工具

当前公开构建脚本面向 macOS，默认 DevEco Studio 位于 `/Applications/DevEco-Studio.app`。其他路径可通过 `DEVECO_STUDIO_HOME`、`DEVECO_SDK_HOME` 与 `OHOS_NATIVE_HOME` 配置。安装项目 `build-profile.json5` 指定的 SDK；脚本沿用 DevEco 自带的 Node、ohpm、Hvigor 和 Java。

## 2. OpenHarmony Go fork

标准 Go 的 Linux / Android 目标不能直接替代本工程的 OpenHarmony TLSDESC 工具链。当前锁定 Go fork 提交为 `302a5306b6fad2f47196360b82561d1db1f954cf`，版本为 Go 1.24.5。自行安装能完成工具链 bootstrap 的 Go，然后：

```sh
mkdir -p .runtime/native-build
git clone https://gitcode.com/openharmony-sig/ohos_golang_go.git .runtime/native-build/ohos_golang_go
git -C .runtime/native-build/ohos_golang_go checkout 302a5306b6fad2f47196360b82561d1db1f954cf
cd .runtime/native-build/ohos_golang_go/src
GOROOT_BOOTSTRAP=/path/to/bootstrap/go GOTOOLCHAIN=local ./make.bash
cd ../../../..
```

也可将 `OHOS_GO_FORK` 指向已构建的工具链目录；脚本检查其提交和可执行文件。具体 OpenHarmony toolchain 兼容性需在你的环境确认。

## 3. 原生内核与 HAP

```sh
bash scripts/build.sh
```

公开入口读取 `native/CORE_LOCK.json`，使用锁定的 libXray 和 HEV 源码，应用仓库补丁，再复制重建产物到 CMake 所需位置。Geo 下载读取 `native/GEO_LOCK.json` 的固定版本和 SHA-256；下载失败时可以自行放置哈希相同的文件到 `.runtime/geo-cache/`。

内核使用历史版本锁定：libXray `20d70a98`、Xray-core `v1.250803.0`、HEV `2.17.1`。这保证源码基线明确，**不代表依赖已做最新安全审计**。更换内核版本需同时核对 ABI、补丁和真实转发行为。

若只需要重建内核及恢复数据文件：

```sh
bash scripts/build.sh --native-only
```

完整命令的未签名产物位于 `entry/build/default/outputs/default/entry-default-unsigned.hap`。构建脚本不安装 App，也不改变手机或电脑 VPN。

`0.5.40` 已在现有 DevEco SDK / OpenHarmony Go 工具链上分别从锁定源码重建 Xray、HEV，产物 SHA-256 与 `CORE_LOCK.json` 一致；也完成了 unsigned HAP 编译和内容检查。尚未在另一套全新安装的 SDK 上复验。

修改 ArkTS 或桥接层时，如本机已有哈希匹配的两个内核，可缩短构建：

```sh
bash scripts/build.sh --use-locked-cores
```

该选项只接受 `CORE_LOCK.json` 中的原始内核 SHA-256；缺失或不匹配时终止。修改内核补丁或升级依赖时使用默认源码重建路径。Go 下载与编译缓存保存在被忽略的 `.runtime/native-build/`；HEV 默认最多四个构建任务，可用 `BUILD_JOBS` 调整。

## 4. 本地签名

仓库的 `build-profile.json5` 未配置签名。用 DevEco Studio 为你自己的设备建立签名配置，保存所需本地证书与 profile；不要提交修改后的签名配置，也不要提交 `*.p12`、`*.p7b` 或密码。发布前复核暂存区。

## 5. 原生实现

生产转发是 `TUN → libhevsocks5tun.so → SOCKS → libxray.so`，N-API 桥为 `libheyvpn.so`。`native/patches/` 包含保护 socket、防回环、生命周期、UDP 事件、进度计数及逐流 App 路由补丁。原生桥只绑定锁定的 Xray CGo ABI 和 HEV；不再包含 sing-box、旧 tun2socks 适配器或子进程启动分支。

构建入口还会生成 `pangolin-build.json`，供实际 App 的诊断和恢复记录读取源码身份；不要手工复制旧身份文件。
