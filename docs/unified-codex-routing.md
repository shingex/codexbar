# 主面板统一接入与容量错误重试

接入开关移到主面板，关闭固定使用当前登录 OAuth 纯净直连，开启恢复上次路由选择。关闭时仍显示第三方列表，点击目标自动开启。设置页只保留账号、Key、模型管理和需保存的目标草稿；没有模式选择或接入开关。

`lastModelRoutingSelection` 只记录 Provider / Key 或 OAuth 标识，模型继续属于 Key。内部模式枚举保留兼容读取；控制工具使用 `routing on|off`，旧 `mode` 命令映射到开关。旧混合路由迁移为接入开启，保留原目标；迁移失败保留配置并显示错误。

关闭接入恢复本功能拥有的接入字段，并确保官方 OAuth 直连；不恢复旧 API Key 认证或旧混合模式。Key 编辑保持不变。官方模型仍保留入站模型、正文和认证；只有 `codexbar` 走选中目标。

## 容量重试实现与原因

共享策略只识别错误封装中的容量拒绝，不搜索成功回答。官方及选定目标的 Responses、compact 都使用同一转发入口；每个请求通过 TaskLocal 预算共享最多 5 次实际上游调用，协议回退也消耗预算，避免重试层数叠加。

等待基准为 5、10、20、30 秒，增加 0–20% 抖动；合法 Retry-After 更长时遵守，超过 120 秒直接返回最后错误。请求开始时固定账号、模型、认证及正文；第三方正文适配稳定序列化。其他错误不会因此获得重试。

SSE 仅暂存最多 64 KiB 的初始生命周期片段，遇到业务输出即转为正常 chunk 转发；业务输出后不重放。容量失败会及时终止原上游，耗尽后发回最后错误并关闭响应。客户端断开会取消上游和退避。远程压缩适配中的容量拒绝也向外传播，不再转换成成功的兜底摘要。

## 修改文件及作用

| 文件 | 作用 |
| --- | --- |
| `codexBar/Models/CodexBarConfig.swift` | 保存上次路由选择，兼容旧内部模式 |
| `codexBar/Services/TokenStore.swift` | 统一开关转换、迁移、目标记忆、回滚及重新加载提示状态 |
| `codexBar/Services/CodexSyncService.swift` | 关闭后确保 OAuth 直连，保留 OAuth 认证 |
| `codexBar/Services/GatewayCapacityRetryPolicy.swift` | 容量识别、退避、Retry-After、共享上游预算及容量错误类型 |
| `codexBar/Services/OpenAIAccountGatewayService.swift` | 官方与目标共用重试、前缀探测、断开取消、协议适配及容量错误传播 |
| `codexBar/Services/AgentControlService.swift`、`scripts/codexbarctl` | 新开关命令和旧命令兼容映射 |
| `codexBar/Views/MenuBarOpenAIModeSections.swift` | 主面板开关和统一账号／模型列表 |
| `codexBar/Views/MenuBarView.swift` | 开关和点击目标的交互、重新加载提示，移除模式浏览状态 |
| `codexBar/Services/MenuBarStatusItemController.swift` | 主面板预热测量使用新视图入口 |
| `codexBar/Views/Settings/SettingsWindowView.swift` | 去除设置开关与模式选择，保留保存交互 |
| `codexBar/Views/Settings/SettingsWindowCoordinator.swift` | 设置目标进入草稿；第三方选择保存后开启接入 |
| `codexBarTests/GatewayCapacityRetryPolicyTests.swift` | 错误识别、SSE 分类和退避规则 |
| `codexBarTests/OpenAIAccountGatewayServiceTests.swift` | 可控上游验证容量重试、取消、快照、压缩与协议回退预算 |
| `codexBarTests/TokenStoreGatewayLifecycleTests.swift` | 开关、目标恢复、迁移及失败保留旧状态 |
| `codexBarTests/CodexModelRoutingTests.swift` | 退出 OAuth 规则与中英文／深浅色开关渲染 |
| `codexBarTests/AgentControlServiceTests.swift` | 控制命令映射到唯一开关 |
| `codexBarTests/SettingsWindowCoordinatorTests.swift` | 设置草稿与新激活语义 |
| `codexBarTests/MenuPanelPresentationTests.swift` | 新主面板入口的布局回归 |
| `codexbar.xcodeproj/project.pbxproj` | 按实际构建递增 Build |
| `README.md`、`AGENTS.md`、`.codex/skills/codexbar/SKILL.md` | 更新操作和兼容边界 |
| `docs/key-model-routing.md`、`docs/unified-codex-routing.md` | 标识旧验收记录，提供当前实现与验收说明 |

## 验证结果

- 版本 **2.0.0，Build 326**，Debug / arm64；完整 XCTest **670 项通过，0 失败**。
- 可控上游覆盖官方及目标路径、JSON / 分片 SSE 容量错误、耗尽、工具输出后不重放、等待取消、停滞上游取消、热切换快照、compact、模型目录不重试、协议回退共享预算、远程压缩错误传播。等待与抖动均可注入，测试不实际等待完整退避周期。
- 主面板与开关已渲染检查；中英文、深浅色、长模型列表和锁定视口布局回归通过。
- `codexbarctl routing --help` 与差异空白检查通过。
- 已覆盖安装 `/Applications/codexbar.app`；版本、Build 和 `codesign --verify --deep --strict` 均通过。运行进程 PID 6974 及启动时间保持不变，未主动重启应用。
- 日志：`/tmp/codexbar-unified-tests.log`；测试产物：`/tmp/codexbar-unified-build/Logs/Test/`。真实账号及当前 Codex 会话仍需手动验收。

## 手动验证

1. 自行重新启动 CodexBar 加载新版。确认主面板有接入开关，设置页和主面板均无旧模式切换。
2. 开关关闭时确认 OAuth 登录及官方直连。点击第三方模型，确认自动开启且出现重新加载 Codex 提示。
3. 重新加载 Codex，在两个会话中选择 CodexBar。切换 Key / Model：不再提示重启，新请求走新目标，进行中的请求保持旧目标。
4. 关闭接入并按提示重新加载 Codex：应恢复 OAuth 直连。再次开启应恢复上次目标；已编辑模型仍保留。
5. 在设置中选择目标后取消，确认真实路由不变；保存后目标才生效。
6. 使用可控上游返回容量拒绝，分别验证官方和 CodexBar 入口等待后恢复；持续拒绝总共最多 5 次并明确结束。生成工具调用后再拒绝时不重放；停止生成应取消等待。

自动测试使用临时配置、合成凭据与本地上游，不主动重启用户的 Codex 或 CodexBar。真实账号端到端操作需按上述步骤确认。
