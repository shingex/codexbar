# codexbar 仓库协作约定

## 基本原则

- 本仓库默认使用简体中文协作。计划、总结、提交信息、PR / Release 文案、构建或上传说明默认写中文，除非用户明确要求英文或上游协议强制英文。
- 不要翻译代码标识符、命令、路径、配置键、环境变量、API 字段、协议字段、文件名、版本号和固定 trailer 键名。
- 优先做窄范围、可回归的改动。不要把一次性修复过程、临时判断或已经关闭的问题继续写进本文档。
- 只有当一条经验会长期影响后续代理判断、验证方式或安全边界时，才补充到 `AGENTS.md`；补充前先检查是否能合并进现有条目，避免重复堆叠。
- `.gitignore` 中仍有 `AGENTS.md` / `Agents.MD` 规则；但当前文件已被 Git 跟踪，修改会出现在 `git status` / `git diff`。如果后续新增同名变体或发现未被跟踪，再先确认 ignore 状态。

## 安全边界

- 如果 Codexbar 能够通过应用或既有服务路径完成相关操作，不要手动编辑 `~/.codex/auth.json` 或 `~/.codex/config.toml`。
- 严禁在日志、输出、错误摘要、提交信息或交付说明中打印 `access_token`、`refresh_token`、`id_token`、API Key 等秘密。
- 如果确实需要底层修复，先说明常规路径应由 Codexbar 应用完成，再做最小修改，并保留与本次问题无关的用户配置。

## OpenAI / Provider 关键链路

- `MenuBarView` 和 `SettingsWindowView` 负责暴露 OpenAI 使用模式与目标选择；真实状态切换应通过 `OpenAIAccountUsageModeTransitionExecutor`、`TokenStore`、gateway 服务和同步服务落地。
- `TokenStore` 是 active provider/account、`effectiveGatewayMode`、`routeTarget`、OpenAI gateway / OpenRouter gateway 生命周期的状态中枢。
- `CodexSyncService` 是把 Codexbar 状态同步到 Codex `auth.json` / `config.toml` 的边界层；修改它或任何写入 Codex 配置/认证文件的逻辑前，必须用真实旧配置样本或等价 fixture 做回归。
- 配置写入必须最小化。不要在同一次改动里混合 `model_provider`、`openai_base_url`、`model_providers` block、gateway 路由、传输行为和旧配置清理；除非用户明确要求迁移，不要删除、重排或覆盖无关键。
- `switchAccount` 的 raw value 仍是 `switch`，这是历史配置和同步协议的一部分；面向用户可以显示“手动模式/手动”。
- `hybridProvider` 表示保留 OpenAI OAuth 登录态，同时把请求目标切到 custom provider 或 OpenRouter；`aggregateGateway` 只聚合 OpenAI OAuth 账号池，不混入 Provider / OpenRouter。
- OpenAI 账号导入必须支持直接选择 Codex 本地 `~/.codex/auth.json`，且只读取必要字段；不得输出 token 内容。
- Codex 原生历史列表还依赖 `~/.codex/state_*.sqlite` 的 `threads.model_provider` 索引。把旧自定义 provider 同步回 OpenAI OAuth 时，只能在 `CodexSyncService` 成功写入后做窄范围历史索引归并，不要手动改 JSONL。
- 当前 gateway 对外监听所有 IPv4 地址：OpenAI gateway 为 `0.0.0.0:1456`，OpenRouter gateway 为 `0.0.0.0:1457`；同步给本机 Codex 的地址保持 `127.0.0.1:1456` / `127.0.0.1:1457`。
- Codex CLI 会按 provider 能力决定 remote compact。同步 Provider / OpenRouter 时应写入非 OpenAI 名称的自定义 `[model_providers.codexbar-*]`，不要只靠 `openai_base_url` 伪装内置 `openai` provider；如果仍收到 `/v1/responses/compact`，gateway 可做 Provider API Key 兜底转发，但源头修复优先在 `CodexSyncService`。

## OpenRouter 状态与模型

- OpenRouter 的模型选择是 Key/account 级状态，优先读取 `CodexBarProviderAccount.openRouterSelection`；旧 provider 级字段只作为迁移和兼容镜像来源。
- 写入某个 Key 的选择时，不得覆盖其他 Key 的 `openRouterSelection`。迁移旧配置时，才把 provider 级选择复制到缺失选择的 Key。
- 新增 OpenRouter Key 不能继承已有模型或当前模型状态；编辑窗口必须能编辑 API Key 和可选 Key 标签，并复用新增/编辑的表单组件。
- 模型选择只由勾选列表决定。`selectedModelID` 为空但 `pinnedModelIDs` 非空是合法状态，表示用户只勾选了模型但未指定当前模型。
- 完整 OpenRouter 模型目录不能写入 `~/.codexbar/config.json` 或 provider 兼容镜像；主配置只保存轻量状态。大目录缓存必须放到独立、有界的缓存文件。
- 菜单栏主面板里的 OpenRouter Key 应展示已勾选模型列表，每个模型都可作为手动切换入口；模型行显示“当前”必须同时满足该 Key 已实际激活，且 `openRouterEffectiveModelID` 等于该模型 ID。
- OpenRouter 模型只能作为 OpenRouter provider/key 的当前模型写入 Codex。切回 OpenAI OAuth 或无默认模型的兼容 Provider 时，`model` / `review_model` 必须恢复 GPT 系列默认模型；切到 OpenRouter 前应把当前 OpenAI GPT 模型保存到 `~/.codexbar/openai-model-state.json`。

## 菜单栏与设置窗口 UI

- 菜单栏主面板高度最高为当前屏幕可见高度的 80%；单次打开期间高度应锁定，顶部标题区和底部工具区固定，中间内容区使用剩余高度并内部滚动。
- 中间内容高度只能由锁定 popover 高度扣除固定 chrome 得出，不要再用内部内容测量结果回写高度；首次打开前的 SwiftUI 预热测量值不得写入 `latestMeasuredContentHeight`。
- OAuth/Model 状态和成本卡应与下方 OpenAI 模式 Tab 列表拆成不同 View；Tab 切换只替换下方列表，不重新构建或测量上方摘要。
- 聚合说明只在聚合模式渲染；不要在手动或混合模式用透明占位制造留白。
- 顶部栏分割线归属于顶部 chrome；调整 header divider 时要同步 `MenuBarPopoverSizing.middleContentHeight` 的固定 chrome 扣减和对应测试。
- 各区块水平内边距、右侧操作槽宽度、按钮高度优先复用 `MenuPanelLayout` 常量；所有可点击元素必须有可见 hover 态，激活态统一放在最右侧。
- 成本详情等 hover 浮层如果带阴影，窗口、content view 和 hosting view 必须透明且不裁切，并为阴影预留边界 padding。
- 设置窗口【开始使用】页遵循底部保存语义：点击模式、账号、Provider/OpenRouter 目标只更新 `SettingsWindowDraft`，只有点击【保存】后才调用真实切换/激活路径。
- OpenAI 分组添加入口使用和 Provider 一致的加号菜单，菜单内提供“在线认证”和“导入”；账号导出放在对应账号行右键菜单中。右键菜单项必须带上被操作对象名称，但不得展示 secret。

## 成本统计与 SSE 热路径

- 成本统计基于独立的本地 cost event ledger / usage event 链路计算，不要改为依赖记录列表、历史会话快照或 `RecordsSnapshotService`。
- 价格更新只改 `LocalCostPricing` 和对应成本测试。涉及“今天”或 local day freshness 的逻辑和测试必须按当前本机时区自然日计算，不要硬编码历史日期。
- 扫描 session JSONL 时优先复用 `SessionLogStore` 中 fingerprint 匹配且 usage summary 已完整解析的 `CachedSessionRecord`；未变化的历史 session 不得反复逐行解析。
- `TokenStore.isRefreshingLocalCostSummaryInBackground` 是状态栏成本刷新动画来源；成本刷新状态机必须在节流、丢弃、交接和失败路径中自洽关闭。
- 打开菜单可以通过 `TokenStore.refreshLocalCostSummaryIfDue(minimumInterval:)` 做轻量增量回补，但不要恢复成每次打开都强制全量扫描 session。
- OpenAI / OpenRouter gateway 的真实 SSE/HTTP 转发路径必须使用 `URLSessionDataDelegate` 按网络 chunk 推送，并复用低分配的 SSE 事件累积逻辑；不要退回逐字节 `AsyncBytes` 或每字节 `Data.append` 扫描。
- CodexBar gateway 转发到兼容 Provider 真实地址时，不能因为系统代理是本机 loopback 就全局禁用代理；只有上游目标 URL 本身是 loopback 时才应用 loopback-safe 禁用策略。兼容 Provider 的 `/v1/responses/compact` 应尽量保留 Codex 原始 compact body，只替换当前 Provider 模型和认证，避免 C 场景经 gateway 失败而 A/B 直连成功。

## 记录页行为

- 会话详情命令区域以内联 `codex resume <sessionID>` 胶囊和复制图标呈现；详情页只展示“活跃”或“已归档”状态，不提供取消归档。
- 会话详情标题行右侧放删除按钮；打开目录按钮和 resume 命令胶囊共享一行，命令空间不足时中间截断。
- 会话列表支持“全部 / 活跃 / 已归档”筛选并持久化到本机偏好；批量管理控件放在筛选控件左侧，不能推挤右侧筛选位置。
- 记录页不要实现取消归档、文件迁移或 sqlite `threads.archived` 写入能力；已归档状态只作只读展示。

## 构建、安装与清理

- 默认不要在任务完成后自动构建 `codexbar.app`。只有用户明确要求构建、安装、交付、发布，或任务本身是修复构建/安装问题/重大运行 bug 时，才执行本机构建。
- “提交代码”不等于“构建交付”。普通代码提交、PR 准备、评审修复或本地验证完成后，不递增 Build 号、不主动安装 `/Applications/codexbar.app`、不做发布级清理。
- 本机构建默认使用当前机器可运行的 Debug / active arch 配置，例如 Apple Silicon 使用 `ONLY_ACTIVE_ARCH=YES` 和 `ARCHS=arm64`。
- 每一次用于交付、安装、发布或让用户实际验证的构建，都必须递增 `CURRENT_PROJECT_VERSION`，并在交付说明里报告版本号和 Build 号。
- Debug 包也遵守 Build 号递增规则：只要本轮 Debug `codexbar.app` 会用于覆盖安装到本机、交付给用户实际验证，或由会产出 `.app` 的 Debug `xcodebuild build` / `xcodebuild test` / 等价验证命令生成，就必须在构建前主动把 `CURRENT_PROJECT_VERSION` 推进 1 个 Build 号；不得因为配置是 Debug、active arch、或只是本机验证而跳过。
- 如果本轮执行过会产出 `.app` 的 Debug `xcodebuild build` / `xcodebuild test` / 等价验证命令，结束前必须用本轮 Debug 产物覆盖安装到 `/Applications/codexbar.app` 并完成安装验证；这不代表可以额外触发发布级构建或完整清理。
- 安装或替换本机构建时，严禁主动关闭、杀掉、重启或重新打开正在运行的 `codexbar` 进程。覆盖安装失败时，应继续尝试不影响运行中实例的替代路径；只有遇到权限、只读文件系统或所有非退出路径都失败时，才报告阻塞。
- 安装任务的完成标准必须包含验证：确认 `/Applications/codexbar.app` 已被本轮产物覆盖，并报告 `CFBundleVersion` / `CFBundleShortVersionString`、签名、目标修改时间或可执行文件一致性等依据。
- 日常测试和本地安装只做必要清理；只有准备远程 PR、Release、上传/分发，或用户明确要求完整清理时，才做发布级清理。不要擅自删除用户保存的归档、DMG、备份或长期副本。

## Xcode 测试验证

- 测试 target / 模块名是 `codexbarTests`，不是 `codexBarTests`。`xcodebuild -only-testing` 过滤路径必须写 `-only-testing:codexbarTests/...`。
- 如果正确大小写的过滤仍报 scheme 或 test plan 找不到目标，先用 `xcodebuild -list` 和当前 scheme/test plan 确认可用目标，不要反复重跑同一条错误命令。
- 改动 `TokenStore`、`CodexSyncService`、gateway、菜单栏主面板、设置窗口或记录页关键链路时，应检查相关源码与测试是否仍同构，并优先跑窄范围测试。

## 图标资产

- 当前正式 AppIcon 源图是 `docs/assets/icon-exploration/2026-05-19-user-provided-icon.png`；Orbital Switch 只是探索稿。
- 只替换图标时，优先保持 `codexBar/Assets.xcassets/AppIcon.appiconset/Contents.json` 的文件名引用不变，覆盖对应 PNG 阶梯即可。

## 断点恢复

- 发生上下文压缩、会话恢复、工具中断或长任务续接后，先核对压缩摘要、最近用户指令、当前 `git status` / diff、已运行命令和未完成验证，再判断断点状态。
- 恢复后先区分“已完成并验证”“已修改但未验证”“尚未开始”“被最新消息改变方向”的事项；如果摘要和当前文件状态冲突，以当前文件状态、实际测试输出和用户最新指令为准。

## 完成任务后的输出

每次完成任务后，请始终说明：

1. 修改了哪些文件
2. 每个文件的作用
3. 核心逻辑是如何实现的
4. 为什么这样实现
5. 我应该如何手动验证

如果没有运行测试或验证命令，也要明确说明。
