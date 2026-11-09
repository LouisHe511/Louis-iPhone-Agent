# Performance and diagnostics / 性能与诊断

## Where time goes / 时间花在哪里

```text
cloud decision → local authorization → input → UI settling → screenshot
     ↑                                                       ↓
     └──── model request ← bounded image ← native frame / OCR ┘
```

Local control uses encrypted authenticated loopback on the same phone. Cellular bandwidth does not carry the local tap RPC. Cloud image upload, provider queueing and inference still use the internet and often dominate a complete task. A first task also pays the helper startup cost; a warm action is a different measurement.

本机点击不经蜂窝网络绕行；模型请求、图片上传和推理仍需要网络。首次启动组件与任务内的后续动作需分开测量，不能把单次点击时间当成整个任务速度。

Current optimizations preserve a native-resolution OCR frame, cap the model image at a true 900-pixel long edge independent of display scale, avoid redundant geometry queries, reuse the local connection and perform large decryptions away from the main actor. Low-confidence Chinese text needs a matching local crop at the same position before acceptance. Actions retain a short settling delay and a fresh screenshot; the model must inspect the visible outcome rather than infer success from delivery alone.

## Local records first / 优先查本地记录

When diagnosing a run, retrieve available app records through Xcode/device tooling before asking the user to copy a log. Narrow the investigation to the failing conversation/run and tool stage. App Documents contains bounded `performance-stages.jsonl` records with fixed stage names, milliseconds, byte counts, a short attempt identifier and a success flag. Stages include `encode`, `first_response`, `total`, `ocr` and `local.*` RPCs. They exclude messages, credentials, tool arguments and images. Timestamps correlate stage records; timings overlap and should not simply be added.

`first_response` is the first provider response event, not a guarantee that the first useful visible token has arrived. `total` includes the request's entire response stream. Local input receipt confirms dispatch, not that the intended business operation completed. Compare repeated comparable runs, report sample count and p50/p95, and separate cold startup, local actions and cloud requests. Do not extrapolate Wi-Fi measurements to cellular service.

排查时先提取本地已有记录，只查看相关会话和故障阶段。性能文件仅记录数值与固定阶段，不包含消息或图片。阶段可能重叠，不能直接相加；首个响应事件也不等于首个可见有效回答。报告样本数与中位数/高分位，分别统计冷启动、本机动作和云端请求。

To summarize a locally retrieved timing file without printing task identifiers:

```sh
python3 tools/summarize_performance.py /path/to/performance-stages.jsonl
# Optional: --since 2026-01-01T00:00:00Z
```

The report separates successes/failures and uses nearest-rank percentiles. It does not include failed durations in successful latency statistics. Preserve network and cold/warm context separately when comparing reports.

## Failure behavior / 出错行为

- A missing or ambiguous OCR target returns the fresh observation and a specific reason. No coordinate guess is sent. Low confidence without successful crop verification is rejected.
- Two consecutive input failures stop the run. Read-only observation does not reset this counter; a successful input does.
- A changed display/session invalidates an observation's action grant. Unknown input outcomes are never automatically replayed.
- Ending a task stops the helper. A new foreground task can start it again; interrupted tasks do not restart themselves.
- The helper listens only on `127.0.0.1:8200`. A LAN self-check is unnecessary for this route. Legacy remote-access failure notifications are cleared at startup.

文字找不到、含糊或置信度不足时，不会猜坐标。新截图可用于重新判断；连续两次输入失败停止。结果未知时不重放，避免重复发送或提交。任务结束后停止组件，新任务可按需启动。

## Reporting a problem / 如何反馈

Use the bug template and include:

- App commit/version, iOS version, selected route and provider/model name (no API key).
- Approximate time with timezone, task or conversation identifier if available, and the last visible step.
- Expected versus actual result, whether a tap/text entry happened, and whether Wi-Fi/VPN/USB were involved.
- Whether the issue follows cold startup, locking, rotation, app switching, an emergency stop or provisioning expiry.

If records are locally accessible to your collaborator, provide the time and task first so they can inspect those records directly. Public issues must not contain private chats, contacts, course content, location, payment details, raw app containers, pairing files or credentials. Attach a minimal redacted excerpt only when needed. Screenshots are optional and must be reviewed/redacted before sharing. Security-sensitive reports follow [SECURITY.md](../SECURITY.md).

反馈故障时间、任务、最后一步、预期和实际结果即可；能直接访问本机记录时，先查记录。公开 issue 不要上传完整应用容器、聊天、联系人、订单、课程内容、位置、配对文件或凭据。需要证据时仅分享已检查的最小脱敏片段。
