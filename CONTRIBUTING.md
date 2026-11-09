# Contributing

This is an experimental fork of Actell. Keep changes focused and preserve upstream license/provenance files. Read [AGENTS.md](AGENTS.md) and [DESIGN.md](DESIGN.md) before editing app behavior or UI. Maintain English and Simplified Chinese UI resources and both READMEs.

Open an issue describing a reproducible problem or send a focused pull request. Include the behavior changed, its reason, relevant checks and remaining limits. Use fixtures rather than real accounts, messages, orders or coursework. Never commit credentials, developer images, signing artifacts or device records.

```sh
python3 ios-app/scripts/check_localizations.py
CC=clang bash devices/esp32/tools/test_usb.sh
bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

App changes also need an iPhoneOS build; local helper changes need `python3 local-control/build.py --unsigned`. See [setup](docs/SETUP.md). State when a check could not run and why. Do not remove authorization, stop/release, session isolation or unknown-result tests to shorten validation. Avoid silently changing dependency pins or restoring personal offline paths.

For latency changes, measure comparable repeated stages and preserve observation/authorization boundaries. A faster RPC is not evidence of faster model reasoning or a successful end-to-end task.

欢迎中文反馈和 PR。先说明可复现行为、修改原因、验证结果及尚未覆盖的限制；遵循国际化和许可约束。安全问题不要在公开 issue 贴出敏感信息。
