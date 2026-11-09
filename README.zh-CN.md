# Louis · iPhone 智能体

[English](README.md) | 简体中文

基于 [Actell / 执言](https://github.com/ja1chen/actell) 的实验性 iPhone 智能体。Louis 将可配置的云端模型与本机截图、OCR 和手机输入连接起来。完成开发者准备后，本机路线可在蜂窝网络下运行，无需 Wi-Fi、VPN、ESP32 或随身电脑。

**这是需要开发者签名安装的原型。** 需要分别安装 Louis 和 **Louis Local Control** 两个 App。仓库发布源码，不是 App Store 版本。签名有效期、开发者服务、系统自动化提示和后台限制仍然存在；不保证任意 App 的完整任务都能成功或无人值守运行。

## 核心能力

- 可配置服务商、模型参数、流式对话、图片附件和文本技能。
- 截图、文字定位、点击、拖动、滚动、输入、启动应用和返回主屏幕。Vision OCR 在手机上处理原始分辨率截图，模型收到缩小的图像。
- Louis 经 `127.0.0.1:8200` 与本机控制组件加密认证通信，模型请求使用手机正常的互联网连接。
- 手机任务按需启动自动化，释放控制后停止；运行期间显示 iOS 自动化提示，仅打开 Louis 不会启动服务。
- 新截图引用、动作与会话授权、结果未知时不自动重放。连续两次输入失败会停止任务并保留诊断上下文。
- 保留可选 VPN/CoreDevice、ESP32 路线以及 [Muse 伴侣连接](docs/muse-remote/README.md)。

## 开始使用

需要安装 Xcode 27 / iOS 27 SDK 的 Mac、开启开发者模式且已解锁的兼容 iPhone、Python 3、Rust 和 XcodeGen。请使用自己的 Apple 签名身份和唯一 Bundle ID 前缀。云端任务需要配置服务商；发送给服务商的截图和消息会离开手机。

1. 按照[构建与安装](docs/SETUP.md)分别安装主 App 和本机控制组件。
2. 通过 Xcode 准备匹配的个性化 Developer Disk Image，并确认系统提示。
3. 在 Louis 的“设置 → 手机操控”选择“本机操控”，长按展开本机配对通知并允许。凭据保存在设备专用 Keychain 中。
4. 配置服务商和模型，先执行无副作用的小任务，检查实际画面结果。

免费签名需要定期续签，通常为七天。手机重启后可能需要 Mac 重新准备开发者服务。本机控制组件使用 XCTest 和私有开发者接口，不能据此认定可以上架 App Store。详见[架构与边界](docs/ON-DEVICE-CONTROL.md)。

## 构建与验证

```sh
python3 ios-app/scripts/generate_xcode_project.py
python3 ios-app/scripts/check_localizations.py
CC=clang bash devices/esp32/tools/test_usb.sh
# 需要 XcodeGen；仅编译独立组件，不使用签名身份：
python3 local-control/build.py --unsigned
# 主 App 测试使用专用模拟器：
bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

Rust 目标、签名构建和真机安装见[安装说明](docs/SETUP.md)。测试使用夹具和临时存储。[GitHub Actions 模板](docs/CI.md)启用后运行可移植源码检查，不负责挂载开发者镜像、签名或证明完整模型任务成功。默认测试 target 保留授权、隔离、未知结果和停止释放覆盖。

## 性能与反馈

本机 OCR 保留原始分辨率，模型图片长边限制为 900 像素；传输复用连接，减少重复几何查询，并分别记录本机与云端阶段耗时。速度仍受界面动画、模型推理和网络影响，不承诺统一延迟。

[性能与诊断](docs/PERFORMANCE-AND-DIAGNOSTICS.md)说明测量方法、本地记录优先排查以及如何提交脱敏反馈。建议先验证食物搜索至下单确认页、自己的聊天草稿、练习内容，并预先定义成功标准；有实际后果的操作请在确认后执行。

## 工程布局

| 路径 | 用途 |
| --- | --- |
| `ios-app/` | 主 App、资源、测试与工程生成器 |
| `local-control/` | 单独构建的本机组件及 Apache-2.0 许可与声明 |
| `coredevice/` | 传统路线使用的 Swift/Rust 后端 |
| `devices/esp32/` | 可选硬件固件与协议测试 |
| `docs/` | 安装、行为、诊断与已知限制 |
| `tools/` | 构建与跨模块检查 |

## 依赖与来源

| 项目 | 用途 |
| --- | --- |
| [Actell](https://github.com/ja1chen/actell) | 主 App 的上游基础，保留原有许可与来源记录 |
| [OpenMinis/iCTRL](https://github.com/OpenMinis/iCTRL) | 本机 XCTest 控制组件，保留独立 Apache-2.0 许可 |
| [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit) | 本地智能体核心与宏源码，含兼容性调整 |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI)、[MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | 模型 API 与 Markdown 展示的 Swift Package 依赖 |
| [idevice](https://github.com/jkcoxson/idevice)、[Device Hub](https://github.com/JaviSoto/device-hub-ios) | CoreDevice 后端复用的补丁源码与 PNG 校验器 |
| [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) | 选取并调整的工具展示组件 |
| [ESP-IDF](https://github.com/espressif/esp-idf)、[esp_tinyusb](https://github.com/espressif/esp-usb)、[TinyUSB](https://github.com/hathach/tinyusb) | 可选固件工具链及 USB 组件，版本见锁文件 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)、[LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | 协议参考与可选外部 VPN；不作为手机内的 Python 服务运行 |

Swift 依赖固定在 Package.resolved，Rust 与固件依赖由各自锁文件记录。完整来源、修改边界与许可见 [THIRD_PARTY](THIRD_PARTY.md)、[iOS 声明](ios-app/Licenses/)和[复用说明](coredevice/docs/REUSE.md)。

## 参与和安全

请阅读 [CONTRIBUTING](CONTRIBUTING.md)、[安全反馈](SECURITY.md)和[已知限制](docs/PROJECT-TODOS.md)。主项目保留上游 GPL-3.0-only 许可，各独立组件保留自身许可。本机组件见 [local-control/UPSTREAM.md](local-control/UPSTREAM.md)。仓库不包含签名身份、开发者镜像、Apple SDK 二进制或真实手机记录。
