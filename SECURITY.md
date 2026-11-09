# Security

Louis is a developer prototype with powerful UI automation. The main app uses developer/testing interfaces through a separately signed helper. Model-visible screenshots and messages are sent to the configured provider. Review provider policies and do not include secrets in tasks.

The local runner is restricted to IPv4 loopback and requires authenticated pairing. Credentials use device-only Keychain storage. This does not isolate it from every malicious or compromised local app, nor does it remove iOS developer-service and signing risks. Do not expose the runner port to a LAN or internet relay. Never automatically replay an input whose outcome is unknown.

## Reporting

For a vulnerability, use this repository's GitHub **Security → Advisories → Report a vulnerability** when available. If private reporting is unavailable, open a minimal issue requesting a private reporting channel without reproduction secrets or sensitive details. Do not post credentials, real pairing files, device containers, private screenshots or a working exploit against another person's device.

Only the current default branch is maintained. There is no security support guarantee for archived source snapshots, legacy routes or third-party services. No credentials or signed binary are required for a useful report.

安全问题优先使用 GitHub 私密漏洞报告。若入口不可用，仅公开请求私密沟通渠道，不贴凭据、配对文件、真实截图或敏感复现细节。当前为实验性开发者原型，不承诺生产安全或历史版本维护。
