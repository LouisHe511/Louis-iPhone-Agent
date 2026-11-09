# Louis · iPhone Agent

English | [简体中文](README.zh-CN.md)

An experimental iPhone agent based on [Actell](https://github.com/ja1chen/actell). Louis combines a configurable cloud model with local screenshots, OCR and phone input. The on-device route operates on cellular data without Wi-Fi, VPN, ESP32 or an attached computer after developer setup.

**Developer-installed prototype.** Two separately signed apps are required: Louis and **Louis Local Control**. This repository is source code, not an App Store release. Device preparation, signing expiry, iOS automation prompts and background limits still apply. Arbitrary app workflows and unattended completion are not guaranteed.

## What it does

- Streaming conversations with configurable providers, model parameters, images and imported text skills.
- Screenshot, text lookup, tap, drag, scroll, text entry, app launch and Home tools. Local Vision OCR uses full-resolution frames; the model receives a smaller image.
- Authenticated encrypted communication with the local runner over `127.0.0.1:8200`. Model requests use the phone's normal internet connection.
- Automation starts for a device task and stops after control is released. iOS displays an automation notice while the runner is active. Opening Louis alone does not start it.
- Fresh observation references, per-action/session authorization and no automatic replay of uncertain input. Two consecutive input failures stop the run and retain diagnostic context.
- Optional legacy VPN/CoreDevice and ESP32 routes, plus an optional [Muse companion](docs/muse-remote/README.md).

## Get started

You need a Mac with Xcode 27 / iOS 27 SDK, a compatible unlocked iPhone with Developer Mode enabled, Python 3, Rust and XcodeGen. Use your own Apple signing identity and a unique bundle prefix. Cloud model use requires an appropriately configured provider; screenshots and messages sent to a provider leave the phone.

1. Follow [build and installation](docs/SETUP.md) to install Louis and the separate local runner.
2. Prepare a matching personalized Developer Disk Image through Xcode and approve required system prompts.
3. In Louis, choose **Settings → Phone control → On-device control** and approve the local pairing notification. Pairing credentials stay in the device-only Keychain.
4. Configure a provider/model. Start with a harmless test task and inspect the visible result.

Free provisioning requires periodic renewal, commonly after seven days. Rebooting the phone can require a Mac to prepare developer services again. The local runner uses XCTest and private developer interfaces; this does not establish eligibility for App Store distribution. See [architecture and limits](docs/ON-DEVICE-CONTROL.md).

## Build and verify

```sh
python3 ios-app/scripts/generate_xcode_project.py
python3 ios-app/scripts/check_localizations.py
CC=clang bash devices/esp32/tools/test_usb.sh
# Requires XcodeGen; compile the helper without a signing identity:
python3 local-control/build.py --unsigned
# Use a dedicated simulator for the main app test suite:
bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

See [setup](docs/SETUP.md) for Rust targets, signed builds and device installation. Tests use fixtures and temporary storage. The [GitHub Actions template](docs/CI.md) runs portable source checks once activated; it does not mount developer images, provision phones or certify complete model-driven tasks. Core authorization, session isolation, unknown-result handling and stop/release tests remain in the default target.

## Performance and problem reports

The local path preserves a native-resolution OCR frame and caps the model image at 900 pixels on its long edge. It reuses transport sessions, removes redundant geometry round trips and records separate local/cloud stage timings. Latency still depends on UI transitions, model inference and network conditions; there is no universal response-time guarantee.

[Performance and diagnostics](docs/PERFORMANCE-AND-DIAGNOSTICS.md) explains measurement, local-first diagnosis and privacy-aware bug reports. Please test food search up to the checkout screen, self-chat drafts and practice content with clear expected results. Review consequential actions before allowing them.

## Repository

| Path | Purpose |
| --- | --- |
| `ios-app/` | Main app, resources, tests and project generator |
| `local-control/` | Separately built local runner, Apache-2.0 source and notices |
| `coredevice/` | Swift/Rust backend for legacy routes |
| `devices/esp32/` | Optional hardware firmware and protocol tests |
| `docs/` | Setup, behavior, diagnostics and known limits |
| `tools/` | Build and cross-module checks |

## Dependencies and sources

| Project | Current usage |
| --- | --- |
| [Actell](https://github.com/ja1chen/actell) | Upstream main application; original license and provenance retained |
| [OpenMinis/iCTRL](https://github.com/OpenMinis/iCTRL) | Separately built local automation runner; Apache-2.0 source and notices |
| [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit) | Local source snapshot of the agent core and macros, with iOS storage compatibility patches; does not include the upstream MCP module |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | Swift Package dependency for model API integration |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Swift Package dependency for Markdown message rendering |
| [idevice](https://github.com/jkcoxson/idevice) / [Device Hub](https://github.com/JaviSoto/device-hub-ios) | Reuses the patched idevice source and PNG validator pinned by Device Hub, with local adaptations; does not integrate the entire Device Hub app |
| [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) | Selected and adapted tool-call presentation components, not a package dependency on the entire framework |
| [ESP-IDF](https://github.com/espressif/esp-idf/tree/v5.5.5), [esp_tinyusb](https://github.com/espressif/esp-usb), [TinyUSB](https://github.com/hathach/tinyusb) | ESP32 firmware toolchain and USB components; pinned to ESP-IDF 5.5.5, esp_tinyusb 2.2.0, and TinyUSB 0.21.0~2 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | Protocol schema reference and selective translation; not a Python service running on the phone or ESP32 |
| [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | Verified external VPN loopback implementation; its Network Extension implementation is not copied into this repository |

Pinned Swift packages are recorded in [Package.resolved](ios-app/PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved); Rust dependencies are in [Cargo.toml](coredevice/rust/Cargo.toml) and [Cargo.lock](coredevice/rust/Cargo.lock). Firmware components are pinned by the [manifest](devices/esp32/firmware/main/idf_component.yml) and [lockfile](devices/esp32/firmware/dependencies.lock). See [licenses and provenance](THIRD_PARTY.md), [iOS notices](ios-app/Licenses/) and [reuse boundaries](coredevice/docs/REUSE.md) for attribution and local adaptations.

[Known limits and remaining work](docs/PROJECT-TODOS.md) · [CoreDevice compatibility](coredevice/docs/COMPATIBILITY.md) · [Background execution](docs/background-execution/IMPLEMENTATION.md) · [Stop and release](docs/CONTROL-SESSION-TEARDOWN.md)


## Contributing and security

Read [CONTRIBUTING](CONTRIBUTING.md), [security reporting](SECURITY.md) and [known limits](docs/PROJECT-TODOS.md). The main project retains its upstream GPL-3.0-only license; independently distributed components retain their own licenses. The iCTRL-derived runner retains Apache-2.0 notices in [local-control](local-control/UPSTREAM.md). No signing identity, developer image, Apple SDK binary or real device record is distributed.
