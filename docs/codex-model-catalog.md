# 在 Codex 中选择模型

设置【开始使用】新增接入方式，修改先进入草稿，保存后生效。新配置默认导出模型，旧 JSON 缺字段时默认跟随 CodexBar。

核心实现：`CodexExportRegistry` 持久保存无凭据的 Provider / account / model 与 UUID 入口映射。gateway 在请求开始时读取配置并固定目标，继续使用已有转发、容量重试和取消路径。目录只导出 Key 自己保存的模型；导出项与原生模型的名称或 slug 重名时，保留原生项，按同名规则给导出项追加 Provider、Key 标签或序号。已删除目标返回错误。历史入口保留隐藏元数据。

修改文件：
- `CodexBarConfig.swift`：接入方式和新旧配置默认值。
- `CodexExportRegistry.swift`：稳定入口、目录生成、名称区分、历史入口和请求目标解析。
- `CodexModelRouting.swift`、`CodexSyncService.swift`：生成和刷新目录，退出时恢复受管理模型默认值。
- `TokenStore.swift`：设置应用、OAuth 登录切换、第三方激活限制与持久重新加载提醒。
- `OpenAIAccountGatewayService.swift`：固定入口路由及目标快照。
- `MenuPanelPresentation.swift`、`MenuPanelProviderCard.swift`、`MenuBarOpenAIAccountSections.swift`：浏览模式及官方账号摘要。
- `MenuBarOpenAIModeSections.swift`、`MenuBarView.swift`：保留重新加载入口。
- `SettingsWindowCoordinator.swift`、`SettingsWindowView.swift`：接入方式草稿与设置选择。
- `AgentControlService.swift`：导出方式下拒绝第三方激活命令。
- `CodexExportRegistryTests.swift`：新旧默认值、稳定 ID、凭据隔离和目标解析。
- `project.pbxproj`：Build 329。

验证：106 项针对性 XCTest 通过，覆盖新增注册表及现有 gateway、配置同步回归。尚未完成真实客户端目录重新读取、多会话端到端与完整测试套件验证。因此当前提示按重新加载 Codex 处理，不宣称客户端能够热读目录。

手动验证：自行重启 CodexBar；设置选择【在 Codex 中选择模型】并保存，开启接入，按提示重新加载 Codex。在两个会话分别选择两个导出入口，确认各自使用固定目标。修改凭据后新请求应使用新凭据；重命名和增删模型应提示重新加载。切回跟随方式，验证历史入口仍可接续。关闭接入后改选官方模型，确认 OAuth 直连。
