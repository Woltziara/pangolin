# 穿山甲 · Pangolin

HarmonyOS NEXT 原生网络隧道客户端，使用 ArkTS、VPN Extension、C++ N-API 桥和 Xray / HEV 数据面。节点与订阅由使用者自行提供。

本次开源的是 `0.4.9-advanced` 当前工作源码。项目处于开发阶段；源码中的功能、离线测试通过和真机可用性是不同的状态，尚未验证全部设备与系统版本。

## 功能

- 分享链接、订阅及配置导入，节点管理与延迟检测。
- 单通道和双通道连接、规则分流、自定义规则与备用节点设置。
- HUKS 运行时凭据保护、本地滚动诊断日志与故障现场导出。
- 原生 VPN 生命周期和 `TUN → HEV → 本地 SOCKS → Xray` 转发。
- 无软件购买、试用或付费解锁门槛。

**按 App 指定节点仍是实验功能。** 代码包含规则、UID 查询与逐流路由实现，但现有真机验证遇到包信息查询权限限制，不能承诺普通第三方应用可在所有设备上使用。节点出口、后台稳定性和网络切换行为也需在目标设备上实测。

## 获取与构建

```sh
git clone https://github.com/Woltziara/pangolin.git
cd pangolin
```

开发环境：DevEco Studio、项目所需 HarmonyOS SDK、Python 3、Node.js、C/C++ 编译工具，以及与锁定提交一致的 OpenHarmony Go fork。当前配置的最低兼容 SDK 为 `6.1.0(23)`，目标 SDK 为 `26.0.0`；请在 DevEco SDK 管理器安装对应 SDK。

仓库发布源码，不携带预编译内核、签名安装包、节点配置、Geo 数据库或开发者签名。请先按 [构建说明](docs/BUILDING.md) 准备 Go 工具链，再运行：

```sh
bash scripts/build-public.sh
```

该命令从锁定的上游版本重建两个内核、恢复校验过的 Geo 数据文件并生成**未签名 HAP**，不会连接或操作手机。DevEco Studio 安装到设备时，需自行配置本地签名和设备授权。签名、节点与订阅资料只保存在本机，禁止提交。

## 离线验证

```sh
cd tests/node-runner
npm ci
npm test
cd ../..
python3 -m unittest discover -s tests -p 'test_*.py'
```

Node 测试覆盖解析、规则、连接策略、取消连接、日志、诊断与数据管理。Python 测试包含构建脚本、转发状态机和本机 C/C++ 测试；部分原始断言依赖开发环境、Geo 或预编译内核，缺少这些依赖时需先准备相应材料。完整 Python 测试当前存在失败，具体结果见 [验证记录](docs/VALIDATION.md)。离线验证不会证明实际 VPN 出口或手机后台稳定性。

## 目录

| 路径 | 内容 |
| --- | --- |
| `AppScope/` | 应用信息和图标 |
| `entry/src/main/ets/` | 页面、导入、规则、存储、诊断与 VPN 生命周期 |
| `entry/src/main/cpp/` | N-API 桥和原生逐流路由 |
| `native/` | 上游版本锁定与补丁 |
| `scripts/` | 公开构建入口、内核重建与开发验证工具 |
| `tests/` | 离线测试和合成测试样例 |

`scripts/r1-build.sh`、签名工具和 `stage1-*` 保留为历史开发工具，不是公开构建入口。它们仍依赖本地开发材料；历史工具不含实际设备目标；使用时须配置自己的目标、环境和本地材料。`device.sh` 与 `r1-build.sh` 要求显式设置 `TONGDAO_SERIAL`。

## 隐私与安全

仓库没有服务器账号或节点订阅。连接时会联系你选择的节点，订阅更新会访问你填写的地址。节点目录和备份可能包含连接凭据；本地诊断应在分享前检查并脱敏。请勿在 Issue 中上传订阅 URL、私钥、节点密码或完整导出文件。

## 许可证与致谢

沿用项目的 **GPL-3.0-or-later** 许可，见 [LICENSE](LICENSE)。本项目使用或改编了 [Hey](https://github.com/popsiclelmlm/Hey) 的原生桥、解析器与构建实现，并使用 Xray、libXray 和 hev-socks5-tunnel；保留其署名和许可，详见 [第三方声明](THIRD-PARTY-NOTICES.md)。
