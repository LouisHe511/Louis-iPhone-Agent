# Build and install / 构建与安装

## Prerequisites / 前置条件

Use macOS with Xcode 27 and its iOS SDK, an iOS 27-compatible physical phone, Python 3, Git, Rust and XcodeGen. Install Xcode command-line tools and select that Xcode. The optional ESP32 firmware needs its own toolchain; it is not required for on-device control.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
# Install XcodeGen using your preferred package manager, for example:
brew install xcodegen
```

You need your own signing configuration. An Apple ID with free provisioning can be used where Xcode permits it; it requires periodic renewal and is not a production distribution solution. Do not share certificates, provisioning profiles or pairing records. Enable Developer Mode on the phone and trust your Mac.

需要自己的签名配置。免费签名存在有效期和系统限制，不等于正式分发能力。手机需开启开发者模式并信任 Mac；不要共享证书、描述文件或配对记录。

## Main app / 主 App

Clone the repository and set your **own** unique full App Bundle ID and Apple development team. The variables are read when generating the project; they are not stored as credentials in source.

```sh
git clone https://github.com/LouisHe511/Louis-iPhone-Agent.git
cd Louis-iPhone-Agent
export ACTELL_BUNDLE_ID_PREFIX=org.example.MyLouis
export ACTELL_DEVELOPMENT_TEAM=ABCDE12345
python3 ios-app/scripts/generate_xcode_project.py
open ios-app/PhoneAgent.xcodeproj
```

Replace both example values. In Xcode, select the PhoneAgent scheme and your phone, resolve Swift packages and build/install. The build compiles the Rust backend. The project retains upstream target names and identifiers internally; this is intentional. Do not replace remote package URLs with paths to another developer's cache.

For an unsigned compile check:

```sh
xcodebuild -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent   -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild   -clonedSourcePackagesDirPath .build/SourcePackages CODE_SIGNING_ALLOWED=NO build
```

The first build needs network access for pinned dependencies. `COREDEVICE_CARGO_OFFLINE=1` is only appropriate after the Rust cache is complete. See [iOS details](../ios-app/README.md).

将示例替换为自己的值，在 Xcode 选择手机后构建安装。第一次构建需要下载固定版本的依赖，离线选项只适用于缓存已完整的环境。

## Local runner / 本机控制组件

The helper is a separately signed app, not a Network Extension. Build it with the same team and your chosen prefix:

```sh
python3 local-control/build.py   --team "$ACTELL_DEVELOPMENT_TEAM"   --bundle-prefix "$ACTELL_BUNDLE_ID_PREFIX"
# Optional direct installation on your own connected phone:
python3 local-control/build.py   --team "$ACTELL_DEVELOPMENT_TEAM"   --bundle-prefix "$ACTELL_BUNDLE_ID_PREFIX" --install YOUR_DEVICE_UDID
```

The script generates a project and output under ignored `local-control/.build/`. The installable output is `LouisLocalControl.app`; do not distribute this personal signed artifact. `--unsigned` verifies compilation only and cannot be installed as-is. The script packages the XCTest runner and removes SDK test frameworks that are supplied by the device's prepared developer image.

Through Xcode, prepare a matching personalized Developer Disk Image and confirm the phone's developer/automation prompts. Unlock the phone. In Louis select **Settings → Phone control → On-device control**, connect and approve the local pairing notification by expanding it. System passcode prompts must be completed in the system UI. The runner and main app retain separate licenses and signing targets.

本机组件要单独签名安装。通过 Xcode 准备匹配的开发者镜像，并在手机系统界面完成自动化授权；Louis 中选择“本机操控”。配对通知需要长按展开后允许。不要把个人签名产物提交到仓库。

## First validation / 首次验证

1. Verify screenshot capture and the harmless app-local tap counter before using model tasks.
2. With developer services ready, turn off Wi-Fi and VPN, enable cellular data and unplug USB. Verify screenshot plus a real harmless input again. Internet connectivity and local input are separate checks.
3. End the task and confirm the automation notice goes away. Start a new task and confirm the helper restarts. An interrupted old run is not replayed.
4. Configure your provider/model and test a small task with a clear visible expected result.

Rebooting, provisioning expiry, locking and system termination can invalidate readiness. Runtime operation without a Mac does **not** establish a computer-free cold start after reboot. Consult [on-device limits](ON-DEVICE-CONTROL.md) and [diagnostics](PERFORMANCE-AND-DIAGNOSTICS.md) before repeating inputs.

先验证截图和无副作用的实际点击，再分别验证蜂窝联网、拔线运行、结束释放以及新任务重启。重启、签名过期、锁屏和系统终止均可能影响可用性；不承诺重启后完全无需电脑准备。
