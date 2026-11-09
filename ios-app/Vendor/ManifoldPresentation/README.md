# ManifoldKit 展示组件摘取

来源：[ManifoldKit/ManifoldKit](https://github.com/ManifoldKit/ManifoldKit)，固定提交 `15c9c2443770c9289c2e93c88a55bdebc4562771`。版权 `Copyright (c) 2026 Rory Ford`，完整 MIT 许可见 [LICENSE](LICENSE)。原始文件 SHA-256 见 [UPSTREAM.json](UPSTREAM.json)。`Upstream/` 保留未经修改的两份源码供比较，不参与编译。

实际编译的是 [PhoneAgent/AgentUI/Components/ToolInvocationView.swift](../../PhoneAgent/AgentUI/Components/ToolInvocationView.swift)。这是源码摘取和适配，不是 ManifoldKit SPM 依赖，也不是整个 ManifoldUI 的兼容实现。

## 实际复用

- `Sources/ManifoldUI/Views/Chat/ToolInvocationView.swift` 的无执行逻辑组件边界及按工具生命周期分派的展示外壳。
- `Sources/ManifoldUI/Theming/ToolInvocationStyle.swift` 中 `PlainToolInvocationBody` 的待批准、执行中、成功和失败视图；保留参数/结果 `DisclosureGroup` 及回调按钮结构。不是仅参考截图重画普通消息气泡。

## 应用适配

- 将 `MessagePart`、`ToolResult`、样式环境及 `ManifoldInference` 导入替换成应用自有 `ToolStep` 和闭包；没有接入 Runtime、TurnDriver 或 Manifold 审批门。
- 中文标题、状态及审批文案，iOS 17 系统颜色；明确添加 requested / approved / executing / denied / cancelled。
- 按用户要求统一为无卡片底色/外框的工具行；所有状态使用相同的小号工具图标，名称保持正文字号和常规字重，图标与名称统一为次要文字颜色。成功状态不显示标签；其余状态保留末尾标签，不再用前置勾选或进度图标区分状态。
- 待授权内容从消息行移入输入框上方的 `ToolApprovalCard`，动作按钮右对齐，详情区独立滚动。原待批准分支在消息流中只展示工具名称与状态；审批回调仍使用完整 ID 校验。
- 参数预览使用实际调用中有界、允许列表内的公开字段；审批卡展示实际动作描述，结果卡保留可展开参数/结果。
- 插入带运行/步骤归属的截图槽。框架的重新认证按钮不适用，未保留。单次批准/拒绝闭包由应用展示适配层验证完整 ID。
- 没有引入自动批准、整会话批准、工具重试、编辑重放或重新生成动作。

`CitationsView` 已审查但未导入：本应用当前工具与 Provider 没有提供 RAG 引用实体，接入空卡或虚构引用不会形成真实能力。`ChatView`、`ChatInputBar`、`MessageBubbleView` 与 `final ChatViewModel`/Runtime 耦合，未摘取；会话列表、气泡、输入框、导航和持久化是 PhoneAgent 自有代码。Markdown 渲染单独使用 MarkdownUI。
