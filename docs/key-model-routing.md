# Key 级模型接入：初版实现记录

当前主面板开关及容量重试行为见 [统一接入与重试](unified-codex-routing.md)。以下 Build 316 验证结果为初版历史记录。

固定入口 `codexbar` 直接使用混合路由的当前目标。启用时先修改设置草稿，保存后才写入接入配置，并显示现有重新加载 Codex 提示；之后切换 Key / Model 只发布 gateway 状态。每个请求捕获开始时的目标。官方模型沿用原模型、正文和入站凭据的透明转发。

API Key 统一保存 `modelSelection.selectedModelID` 和 `pinnedModelIDs`。Provider 继续管理请求地址、协议和可选名称；OAuth 账号保持独立。这样可以避免两套目标状态不同步，也避免 Provider 默认模型在多个 Key 间串用。

读取支持旧 `openRouterSelection` / `thirdPartyModelSelection`；新写入统一字段。缺模型的旧 Key 不在加载时补齐。新增或编辑 Key 的服务入口和表单均要求请求地址、凭据和明确的当前模型；Provider 公共编辑单独处理，不触碰 Key。允许自定义 ID，不要求在线验证；OpenCode 的目录刷新由用户触发，刷新不改写当前选择。

当前关闭接入固定回到 OAuth 纯净直连，保留已保存的 Key 编辑。上一版独立目标和手填 OAuth 模型字段不再读取或写入，也不会迁移进 Key。OAuth 请求模型来自既有 GPT 设置。

## 本轮文件及作用

| 文件 | 作用 |
| --- | --- |
| `codexBar/Models/CodexBarConfig.swift` | 统一 Key 模型结构和旧字段解码；Provider 名称回退；记录接入前模式 |
| `codexBar/Services/CodexBarConfigStore.swift` | 移除加载时自动向 Key 填充模型，保留旧配置兼容读取与独立目录缓存 |
| `codexBar/Services/TokenStore.swift` | 新增与编辑模型校验；Provider 公共编辑；混合目标热切换；接入与退出模式恢复 |
| `codexBar/Services/CodexSyncService.swift` | 从实际 Key 读取请求模型，复用现有接入配置同步 |
| `codexBar/Services/CodexModelRouting.swift` | 删除独立路由目标类型 |
| `codexBar/Services/CodexPaths.swift` | 原子替换安全文件，消除并发写入的删除空窗和移动冲突 |
| `codexBar/Services/AgentControlService.swift`、`scripts/codexbarctl` | 控制接口支持 Key 模型输入与公共信息编辑 |
| `codexBar/Views/Settings/SettingsWindowCoordinator.swift` | 开关、混合模式、目标进入草稿，取消不影响真实路由 |
| `codexBar/Views/Settings/SettingsWindowView.swift` | 去掉手填模型与独立目标；复用重启提示；连接统一表单 |
| `codexBar/Views/AddProviderSheet.swift` | 统一新建和编辑 Key 的模型列表与当前模型；Provider 公共编辑独立保存 |
| `codexBar/Views/OpenRouterMenuViews.swift` | 编辑仅使用该 Key 的模型，要求明确当前模型 |
| `codexBar/Views/OpenCodeModelPickerSection.swift` | 支持自定义模型 ID；刷新目录保留模型选择，移除自动补选 |
| `codexBar/Models/MenuPanelPresentation.swift` | 主面板目标从共享混合路由状态解析 |
| `codexBar/Views/MenuPanelProviderCard.swift` | 普通兼容 Provider 也显示 Key 级模型选择 |
| `codexBar/Views/MenuBarOpenAIAccountSections.swift`、`MenuBarOpenAIModeSections.swift` | 显示共享目标并使用混合激活动作 |
| `codexBar/Views/MenuBarView.swift`、`MenuPanelManagementMenus.swift` | 菜单表单接入统一模型及公共信息编辑入口 |
| `codexBar/Views/CompatibleProviderRowView.swift`、`ProviderUsageSummaryView.swift` | 使用 Provider 显示名称回退 |
| `codexBarTests/KeyModelSelectionTests.swift` | 旧字段兼容、不强修旧 Key、保存校验、多 Key 隔离、自定义模型与并发原子写回归 |
| `codexBarTests/CodexModelRoutingTests.swift`、`TokenStoreGatewayLifecycleTests.swift` | 草稿混合模式、热切换、OAuth 登录隔离和不重复同步 |
| `codexBarTests/CodexBarConfigStoreTests.swift`、`TokenStoreSettingsTests.swift` | 更新迁移与模型保存的旧预期，覆盖多种 Provider |
| `codexBarTests/AgentControlServiceTests.swift` | 控制接口写入模型与凭据隐藏回归 |
| `README.md`、`AGENTS.md`、`.codex/skills/codexbar/SKILL.md` | 更新操作方式、配置约定和控制参数 |
| `codexbar.xcodeproj/project.pbxproj` | 递增构建版本 |
| `docs/key-model-routing.md` | 本轮实现与验收说明 |

## 手动验证

按 [当前验收步骤](unified-codex-routing.md) 验证。

## 验证结果

- 版本 2.0.0，Build 316；Debug / arm64 完整 XCTest：653 项通过，0 失败。
- 系统 CLI 与桌面版内置核心：4 组离线 HTTP 回退、连续请求及实际工具执行探测全部通过。
- 已覆盖安装 `/Applications/codexbar.app`，版本、Build 和 `codesign --verify --deep --strict` 检查通过。运行中进程 PID 95748 及启动时间保持不变，未主动重启应用。
- 中文/英文、浅色/深色接入卡片渲染检查通过；图形界面与真实账号端到端验收仍需手动执行。
- 测试日志：`/tmp/codexbar-keymodel-tests.log`；离线探测：`/tmp/codexbar-keymodel-http-probes.jsonl`。

## 验证范围

完整 XCTest 包含官方透明转发、分片 SSE、延迟首包、长输出时间预算、停滞超时、取消、compact、目标快照与旧配置恢复。长时间场景通过注入时间参数验证。

`verify-codex-http-fallback.py` 使用临时配置、合成凭据和本地上游，验证系统 CLI 与桌面版内置核心：每个核心分别以正常和强制 WebSocket 探测运行，均在收到 426 后走 HTTP，完成连续请求与实际工具执行。这属于离线核心验证，不等同于真实账号、桌面图形界面的完整端到端验收。真实上游可用性和用户账号权限仍需上述手动步骤验证。
