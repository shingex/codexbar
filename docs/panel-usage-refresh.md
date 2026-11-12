# 打开面板时刷新用量

开关关闭显示“连接 Codex”，开启显示“已连接Codex”。移除顶部手动刷新按钮，打开面板时尝试刷新，接口未到期时使用缓存。

调查：OpenCode Go 的公开文档描述了套餐窗口和客户端要求，但未给出 usage 查询的固定轮询配额：https://opencode.ai/docs/console/go/ 。OpenAI 的 API 限流文档建议避免突发、遵守 Retry-After 和退避，但其 API 配额不能作为 ChatGPT WHAM 私有用量接口的安全阈值：https://help.openai.com/en/articles/5955604-troubleshooting-api-rate-limits-and-429-errors 。因此没有“保证不会 ban”的最小间隔，本轮采用 5 秒作为面板刷新的正常最小间隔，不将其视为服务端保证。

默认同一请求缓存至少 5 秒；并发请求合并。429 冷却从 15 分钟递增至 60 分钟，403 冷却 30 分钟；合法 Retry-After 更长时按服务端要求等待。传输失败也冷却 5 分钟。打开面板时，普通 Provider 和 OpenCode Go 均使用 5 秒门槛。Provider 设置的查询周期仅用于后台轮询。后台轮询与面板共享限制，不因反复打开面板或点击其他刷新入口绕过。凭据只用于内存缓存隔离，不写入日志或缓存文件。

修改文件与作用：
- `MenuBarOpenAIModeSections.swift`：状态文案。
- `MenuBarView.swift`：移除顶部按钮，打开面板触发节流刷新，批量 OAuth 查询串行化。
- `TokenStore.swift`：打开面板时按统一的 5 秒门槛调度已配置的 Provider 用量。
- `UsageHTTPRefreshClient.swift`：共享缓存、并发合并、限流退避。
- `WhamService.swift`、`OpenCodeUsageService.swift`、`ProviderUsageService.swift`：所有用量查询复用统一 HTTP 限流层。
- `UsageHTTPRefreshClientTests.swift`：冷却、服务端指示和重复请求复用用例。

验证：Swift 语法解析和差异检查通过。新增测试尚未运行，未进行 Xcode 类型检查、构建或安装。未对真实账号进行压力测试。

手动验证：开关两种状态的文字正确；顶部没有刷新按钮；间隔内连续关闭和打开面板不产生重复用量网络请求；到期后重新打开会刷新；在可控上游下返回 429 + Retry-After，确认后续打开使用缓存且不提前重试。缺少用量配置的 Provider 不发请求。


## 自定义后台周期

「设置 → 用量」可保存 OpenAI 的自动查询间隔，默认 300 秒；Provider 编辑器也以秒录入。0 关闭后台轮询，正数至少为 5 秒。旧 Provider 的 `intervalMinutes` 按 60 倍读入，保存时写 `intervalSeconds`；已有秒值优先。未配置间隔的 OpenCode Go 默认 900 秒。打开面板的 5 秒门槛和接口退避与该设置独立。

- `UsagePollingInterval.swift`：默认值、间隔归一化和计时单位转换。
- `CodexBarConfig.swift`：OpenAI 持久化字段及旧 Provider 配置迁移。
- `OpenAIUsagePollingService.swift`、`TokenStore.swift`：按秒调度；保存后更新后台任务。
- `SettingsWindowCoordinator.swift`、`SettingsSaveRequestApplier.swift`：保存、取消及写入配置。
- `SettingsWindowView.swift`、`Localization.swift`：用量页输入和秒单位文案。
- `CodexBarConfigStoreTests.swift`、`TokenStoreSettingsTests.swift`：兼容回归用例和秒单位 fixture。

手动验收：在用量页将 OpenAI 保存为 30 秒，再改成 0，观察后台查询是否调整并停止；取消未保存的修改应保持原周期。旧 15 分钟 Provider 在编辑器中应显示 900 秒。0 不会禁用打开面板时的到期查询。
