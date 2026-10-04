# 0.4.10 验证记录 · 2026-10-04

当前交付是已构建、通过离线验证的开发候选；本轮尚未在手机运行。

## 已验证

- 现有 DevEco / HarmonyOS SDK 完成 ArkTS 与 C++ 编译、打包和 packing check，生成 `0.4.10 / 1000096` unsigned HAP。
- 分别从锁定源码重建 Xray 与 HEV，两个原始 `.so` 的 SHA-256 均与 `native/CORE_LOCK.json` 一致。
- 打包后的 Xray、HEV 与 `0.4.9-advanced` 基线逐字节一致。原生桥从 419,760 字节降到 350,936 字节。
- Node 默认入口执行全部 28 个测试文件，通过；包括真实 ArkTS 解析、路由、HUKS、连接取消、日志、诊断与实际 C++ 生命周期代码测试。
- 14 项 Python / 原生检查全部通过，另有 2 项真实 HEV UDP 第一包测试通过。检查覆盖 ABI 声明与调用、App 流请求隔离、HEV 诊断计数、并发 fd 释放、ProcNet 权限拒绝锁存、固定版本补丁及 HAP 内容。
- 对本轮实际打过补丁的 HEV 源码运行 TCP 背压、读写等待方向及 UDP 第一包测试。
- HAP 内容检查确认存在生产 Xray / HEV 内核，不包含实验内核或私有运行配置。

## 测试范围变化

初始公开快照的完整 Python 测试为 375 项，其中 22 项失败、2 项异常、4 项跳过。此次未以删除失败来宣称“原来的 375 项全过”：旧 Python 开发流程及其模拟器、快照断言一起退役，承接关系见 [维护说明](MAINTENANCE.md)。当前通过结论仅适用于当前保留的生产行为与构建检查。

App 流路由原生测试之前的 SIGABRT，已定位为 macOS 测试子进程默认仅允许 256 个文件描述符，而容量测试需要 128 对 socket。提高该测试子进程的额度后，原有容量、取消及迟到回调测试通过；没有修改 App 流路由生产代码来迁就测试。

## 复验

```sh
bash scripts/test.sh
HEV_WORK_DIR=/path/to/patched-hev-workdir python3 -m unittest discover -s tests -p 'test_*.py'
HEV_WORK_DIR=/path/to/patched-hev-workdir python3 tests/hev_udp_first_packet_test.py
```

`HEV_WORK_DIR/src` 必须是应用了本仓库补丁的真实 checkout。`PANGOLIN_HAP` 可指定要检查的 HAP；默认检查当前 unsigned 输出。缺少这些材料的检查会明确跳过，不计作已验证。

## 尚未验证

- 新版本真机安装、实际连接出口、后台持续使用和耗电；当前未检测到指定手机的 USB 连接。
- App 指定节点仍有已知平台权限限制，离线验证不解除该限制。
- 另一套全新安装 SDK / Go 工具链上的构建。

本轮不以源码或二进制缩小，推断真实速度、耗电或稳定性已经改善。
