# CodexBar 项目约定

## 项目与代码入口

CodexBar 是 macOS 13+ 的 Swift / SwiftUI 菜单栏应用，管理 Codex Desktop / CLI 的 OpenAI OAuth 账号、兼容 Provider、OpenRouter、用量成本、会话记录和 Skills。共享一个 `~/.codex`，通过最小配置同步保持 Codex 的历史和登录兼容性。Xcode 工程为 `codexbar.xcodeproj`，测试 target 为 `codexbarTests`。

- `codexBar/Models`：配置、展示模型和模式切换执行器；`Views`：菜单栏与设置窗口；`Services`：状态、同步、gateway 和本地数据服务。对应测试在 `codexBarTests`。
- `TokenStore` 是账号、Provider、路由和 gateway 生命周期的状态中枢；`OpenAIAccountUsageModeTransitionExecutor` 执行模式切换，`CodexSyncService` 负责同步 Codex 认证和配置。
- `OpenAIAccountGatewayService` / `OpenRouterGatewayService` 分别监听 `0.0.0.0:1456` / `0.0.0.0:1457`；同步给本机 Codex 的地址使用 `127.0.0.1`。`AgentControlService` 和 `scripts/codexbarctl` 提供运行中应用的本地控制入口，操作说明见 `.codex/skills/codexbar/SKILL.md`。
- `SessionLogStore`、`RecordsSnapshotService` 负责会话数据；`LocalCostSummaryService` 及 cost / usage event ledger 负责独立的本地成本统计；`CodexSkillService` 管理本机 Skills。

## 协作与安全

- 默认使用简体中文；代码标识符、命令、路径、配置键、协议字段和版本号等保持原样。优先窄范围、可回归的修改，避免过度防御性编程。
- 优先通过应用或 `codexbarctl` 操作账号和配置，不要手动编辑 `~/.codex/auth.json` 或 `~/.codex/config.toml`。确需底层修复时先说明常规路径，并最小化修改、保留无关配置。
- 禁止在日志、输出或交付说明中泄露 token、API Key 等秘密。安装或转换 Skill 到 `~/.codex/skills` 时，在其 `SKILL.md` 前 80 行标注来源仓库。
- UI 不展示实现方式，除非有助于用户操作。可点击元素应有可见 hover 态，布局优先复用现有组件和 `MenuPanelLayout` 常量。

## 核心兼容边界

- `CodexSyncService` 和任何 Codex 认证 / 配置写入逻辑的修改，必须用真实旧配置样本或等价 fixture 回归；配置写入只改必要字段，未经明确迁移要求不得删除、重排或覆盖无关键。`model_provider = "openai"` 是兼容边界，不得改成自定义名称。
- 手动模式的 `switchAccount` raw value 是 `switch`；`hybridProvider` 保留 OpenAI OAuth 登录态并路由到兼容 Provider / OpenRouter；两者仅为内部兼容值，主面板接入开关是唯一交互状态；聚合模式已移除，旧 `aggregate_gateway` 配置迁移为 `switch`。启用按模型分流时，只有 `codexbar` 进入选定目标，官方模型必须保留入站凭据和原始请求。
- OpenAI 账号导入须支持选择本机 `~/.codex/auth.json`，只读取必要字段。旧自定义 provider 的历史索引归并只能在同步成功后窄范围更新 `state_*.sqlite` 的 `threads.model_provider`，不要修改 JSONL。
- 所有 API Key 使用统一 `modelSelection`：写入不得覆盖其他 Key；新 Key 不继承 Provider 或其他 Key 的模型。旧数据缺少当前模型仍可读取；新增或编辑 Key 必须指定当前模型，Provider 公共编辑不强制修复 Key。完整模型目录存独立有界缓存，不写入主配置。切到 OpenRouter 前保存 OpenAI GPT 模型；切回 OpenAI OAuth 或无默认模型的兼容 Provider 时恢复 GPT 默认模型。
- 容量错误是官方透明转发的唯一业务重试例外：仅识别错误封装中的指定容量消息，每个入站请求共享 5 次上游预算（含协议回退），不跨账号或模型。已输出业务内容不重放；退避、流和上游连接必须响应取消。
- gateway 的 SSE / HTTP 转发使用 `URLSessionDataDelegate` 按网络 chunk 推送并复用 SSE 累积逻辑；只在上游目标本身是 loopback 时禁用代理。兼容 Provider 的 `/v1/responses/compact` 保留原始 body，按需替换模型和认证。
- 成本统计不得依赖记录列表或历史快照；复用 `SessionLogStore` 中未变化且解析完整的缓存，菜单打开时只做节流后的增量回补。涉及“今天”的计算和测试使用本机时区自然日。

## UI 与记录行为

- 菜单栏面板高度不超过屏幕可见高度的 80%，单次打开期间锁定；顶部和底部固定，中间内容内部滚动。高度由锁定值扣除固定 chrome 得出，预热测量不得写入正式测量值。摘要与模式列表分离，切换 Tab 不重建摘要。
- `codexbar` 固定入口复用当前路由目标；接入开关位于主面板，关闭固定回到 OAuth 纯净直连，开启恢复上次目标。点击第三方目标自动开启；日常目标切换不重写 Codex 接入配置。旧混合配置升级为接入开启，失败保留旧配置。
- 设置窗口【开始使用】页的模式和目标选择先写入 `SettingsWindowDraft`，点击【保存】后才执行真实切换。
- 记录页支持全部 / 活跃 / 已归档筛选和删除；归档状态只读，不实现取消归档、文件迁移或写入 sqlite `threads.archived`。

## 构建与验证

- 默认不自动构建或安装；仅在用户要求构建、安装、交付、发布，或任务本身是修复构建 / 安装问题、重大运行 bug 时构建。普通提交不递增 Build、不安装或做发布级清理。
- 本机构建默认使用 Debug / active arch。任何用于交付或实际验证的构建，以及会产出 `.app` 的 Debug `xcodebuild build` / `test` 或等价命令，必须先将 `CURRENT_PROJECT_VERSION` 加 1。执行上述 Debug 构建后，结束前必须用本轮产物覆盖安装 `/Applications/codexbar.app` 并验证版本、Build 和签名等；交付时报告版本和 Build。
- 安装时不得主动关闭、杀掉、重启或重新打开正在运行的 `codexbar`；覆盖失败时先尝试不影响运行实例的方式。日常仅做必要清理，不删除用户保存的归档、DMG、备份或长期副本。
- 关键链路改动应检查相关源码与测试并优先做窄范围验证。测试过滤使用 `-only-testing:codexbarTests/...`；如目标找不到，先用 `xcodebuild -list` 和 scheme / test plan 核对。
- 完成编程任务时说明修改文件及作用、核心实现及原因、手动验证方法，并如实报告测试或未验证情况。
