# codexbar 仓库协作约定

## 默认工作语言

- 本仓库的默认工作语言是简体中文。
- 代理、脚本说明、协作文本、交付说明默认使用中文，除非用户明确要求英文，或上游平台/协议强制要求英文。

## 文案语言范围

以下内容默认使用中文：

- Git 提交信息的标题与正文
- Pull Request 标题、描述、评审回复和变更摘要
- Release 标题、Release Notes、发布说明
- 构建包、安装包、构建产物上传时附带的说明文字
- 面向仓库协作的计划、结论、执行记录和汇报

## 保留原文的内容

以下内容不要为了“中文化”而强行翻译：

- 代码标识符、类型名、函数名、变量名
- 命令、路径、配置键、环境变量名
- API 字段、协议字段、第三方平台固定字段
- 构建产物文件名、安装包文件名、版本号、标签名

## 提交协议补充

- 提交信息默认写中文。
- 如果存在必须遵守的上层提交协议或固定 trailer 键名，保留协议要求的键名，其余提交内容和 trailer 值使用中文。
- 除非用户明确要求，不要在这个仓库里默认产出英文提交信息或英文发布说明。

## 安全守则
如果 Codexbar 能够执行相关操作，请勿手动编辑 ~/.codex/auth.json 或 ~/.codex/config.toml 文件。
严禁在日志、输出内容或摘要中打印 access_token、refresh_token 或 id_token。
如果确实需要进行底层修复，在直接编辑身份验证或配置文件之前，务必先说明常规操作路径是通过 Codexbar 应用来完成的。

## OpenAI 账号关键链路

- 当前实现里，`MenuBarView` 和 `SettingsWindowView` 负责暴露 OpenAI 的使用模式与目标选择；模式切换再交给 `OpenAIAccountUsageModeTransitionExecutor`、`TokenStore` 和各个 gateway 服务落地。
- `TokenStore` 是这条链路的状态中枢，负责 active provider/account、`effectiveGatewayMode`、`routeTarget`、以及 OpenAI gateway / OpenRouter gateway 的生命周期。
- `CodexSyncService` 是唯一负责把当前配置同步到 Codex `auth.json` / `config.toml` 的层；`switch` / `aggregate` / `hybrid` 的写入结果必须和当前 active provider 与账号使用模式一致。
- OpenAI 账号导入必须支持直接选择 Codex 本地 `~/.codex/auth.json`；导入面板默认定位到该文件，解析时只读取 `tokens.access_token` / `tokens.refresh_token` / `tokens.id_token`、`client_id`、`last_refresh` 和 `tokens.account_id` 等必要字段，不得在日志或错误摘要中输出 token 内容。
- `switchAccount` 的配置 raw value 仍是 `switch`，这是历史配置与同步协议的一部分；面向用户的展示文案使用“手动模式/手动”，不要为了文案改名迁移 raw value。
- Codex 原生历史列表不只依赖 `~/.codex/sessions/*.jsonl`，还依赖 `~/.codex/state_*.sqlite` 的 `threads.model_provider` 索引；把旧自定义 provider 同步回 OpenAI OAuth 时，必须在 `CodexSyncService` 成功写入 `auth.json` / `config.toml` 后窄范围归并旧 provider 的历史索引，不要手动改 JSONL 或泄露 token。
- 配置写入改动必须最小化：不要把 `model_provider`、`openai_base_url`、`model_providers` provider block、gateway 路由、WebSocket / HTTP-only 行为和旧配置清理混在同一次改动里。`[model_providers.*]` 本身可以使用，但只能在明确需要时做窄范围增量；不得为了修一个问题大面积重写用户已有 `config.toml` 结构。
- 修改 `CodexSyncService` 或任何会写 `~/.codex/config.toml` / `~/.codex/auth.json` 的逻辑前，必须先用真实旧配置样本或等价 fixture 做回归；除非用户明确要求迁移，不要删除、重排或覆盖与本次问题无关的既有配置键。
- `hybridProvider` 的语义是保留 OpenAI OAuth 登录态，同时把请求目标切到 custom provider 或 OpenRouter；`aggregateGateway` 只覆盖 OpenAI OAuth 账号池，不把 provider / OpenRouter 混入聚合。
- 当前 gateway 监听在所有 IPv4 地址上，OpenAI gateway 走 `0.0.0.0:1456`，OpenRouter gateway 走 `0.0.0.0:1457`；Codex 本机同步配置仍写 `127.0.0.1:1456` / `127.0.0.1:1457` 作为桌面端稳定访问地址。手机端需要使用 Mac 的局域网 IP 加对应端口访问；如果后续端口或路由边界变化，要同步更新这里和相关测试。
- OpenRouter 可添加大量模型，但菜单栏主面板必须保持固定、短列表展示；不要在 `OpenRouterProviderRowView` / `OpenRouterKeyRowView` 或等价主面板入口中全量展开 `pinnedModelIDs`。完整模型管理应放在独立编辑窗口，主面板每个 Key 只展示当前模型和隐藏数量摘要，避免自适应弹窗高度随模型数量反复抖动。
- 菜单栏主面板高度最高限制为当前屏幕可见高度的 80%；Provider / OpenRouter 账号过多时必须让内容在面板内部滚动，不要通过继续撑高 popover 来展示长列表。
- 菜单栏主面板单次打开期间不得随着实时内容测量、刷新、Tab 切换或账号/模型列表变化继续调整 popover 高度；打开前只确定一次高度，打开后顶部标题区和底部工具区保持固定高度，中间内容区使用剩余高度并在内部滚动。
- 菜单栏主面板采用顶部标题区、中间滚动区、底部工具区三段式布局；中间滚动区高度只能由打开时锁定的 popover 高度扣除固定 chrome 得出，不得再用内部内容测量结果回写中段高度，否则账号状态刷新、倒计时或模型列表变化会导致内容不定时跳动。
- 菜单栏主面板中间区域必须保持整体滚动语义，不要把账号状态、成本卡或 Tab 控件拆成置顶固定区；修复 Tab 切换抖动时应约束 Tab 区内部的动画和测量影响，避免 Tab 面板内容变化扰动上方视图的位置。
- 菜单栏顶部栏下面的分割线归属于顶部 chrome，不属于中间滚动内容；调整 header divider 时要同步 `MenuBarPopoverSizing.middleContentHeight` 的固定 chrome 扣减和对应测试。
- OpenAI 模式 Tab 下方的模式说明区必须在手动、聚合、混合三种模式保持一致高度；如果只有聚合模式展示说明，其他模式也要保留等高透明占位，避免切换 Tab 时因上方高度不一致造成视图跳动。
- 菜单栏主面板中各区块内部元素必须共享同一套水平内边距和右侧操作槽宽度，优先复用 `MenuPanelLayout` 常量；不要在成本卡、账号行、Provider 卡片或 OpenRouter 模型行里各自写不同的水平 padding，避免右侧按钮/对勾形成多条视觉对齐线。
- 成本详情等由 hover 触发的浮层如果带阴影，窗口边界必须预留透明 padding 承载阴影，视觉卡片尺寸与定位再在内部抵消；不要让 SwiftUI 阴影贴着 `NSHostingController` 根视图边界，否则 AppKit 弹窗会裁掉阴影。
- 从 1.6.0 起，OpenRouter 的模型选择属于 Key/account 级状态：每个 OpenRouter API Key 独立保存当前模型、固定模型列表和缓存目录；旧 provider 级 `selectedModelID` / `pinnedModelIDs` / `cachedModelCatalog` 只能作为迁移和兼容镜像来源，新逻辑必须优先读取 `CodexBarProviderAccount.openRouterSelection`。
- OpenRouter per-Key 选择写入后可以同步 provider 级字段作为旧配置兼容镜像，但刷新或编辑某个 Key 时不得覆盖其他 Key 的 `openRouterSelection`；迁移旧配置时才把 provider 级选择复制到缺失选择的 Key。
- OpenRouter 添加和编辑 Key 必须共享同一套编辑窗口；新增 Key 时不能继承任何已选模型或当前模型状态，只能继承可复用的缓存目录。API Key 与 Key 标签输入框必须由新增/编辑共用的组件承载，不要在两个窗口分支里各自维护一份相似表单。
- OpenRouter Key 编辑窗口必须能直接编辑原 API Key 和可选 Key 标签；Key 标签是菜单栏主面板里的主要显示名。模型选择只由勾选列表决定，不要保留“手动 model ID”输入，也不要在保存时自动把第一个已选模型设为当前模型。
- OpenRouter 模型列表只有没有 cached models 时才自动刷新；已有 cached models 时必须由用户手动刷新。空搜索状态可以只显示已选模型，搜索后再显示匹配结果。
- OpenRouter Key 新增/编辑窗口的模型选择器只在窗口打开时把已选择模型置顶一次；用户在本次搜索/选择过程中新增勾选的模型不得反复跳到顶部。模型列表左侧必须与搜索框等表单元素对齐，刷新成功只更新顶部缓存状态，不要在列表下方重复显示“已刷新 N 个模型”。
- OpenRouter 完整模型目录属于大体量缓存，不得写入主配置 `~/.codexbar/config.json` 或兼容 provider 镜像；主配置只保留当前模型、勾选模型 ID、账号和路由所需的轻量状态。历史污染配置在启动迁移时必须自动剥离 `cachedModelCatalog` / `modelCatalogFetchedAt`，如需跨重启缓存模型目录，必须放到独立且有界的缓存文件。
- OpenRouter 配置里 `pinnedModelIDs` 或 `openRouterSelection.pinnedModelIDs` 已有值但 `selectedModelID` 为空时，表示用户只勾选了模型但未指定当前模型，这是合法轻量状态；启动迁移不得因此扫描历史会话或自动恢复最近模型，只有完全没有 OpenRouter 模型选择信息的旧配置才允许走历史兜底恢复。
- 菜单栏主面板里的 OpenRouter Key 必须完整展开展示已勾选模型列表，每个模型都作为手动切换入口；不要在主面板里用当前模型、选中态、对勾、`selectedModelID` 或“另有 N 个模型/管理”摘要来收敛展示。
- 菜单栏主面板里所有账号、Provider 账号和 OpenRouter 模型条目的激活态必须统一放在最右侧：当前真正激活的条目显示对勾，未激活条目显示“使用/切换”按钮。不要在行中部、标题后方或左侧边条重复显示当前态；可右键操作的行或卡片必须有 hover 态。
- 普通兼容 Provider 的每个 Key/账号都必须提供独立编辑入口，可编辑账号名称和 API Key；编辑非当前激活 Key 时不得顺手切换 `activeAccountId` 或 `config.active.accountId`，只有正在被 Codex 使用的 Key 被编辑时才同步当前配置。
- 菜单栏主面板所有右键菜单项不能只显示泛化的“编辑”或“删除”，必须在菜单项文字里带上被操作对象，例如 Provider 名、Provider 账号名、OpenRouter Key 标签或 OpenAI 账号邮箱；但仍然不得展示 API Key 或 token。
- 菜单栏 OpenRouter 模型行的“当前”必须同时满足当前 OpenRouter Key 已实际激活，且该 Key 的 `openRouterEffectiveModelID` 等于该模型 ID；只勾选但未使用的模型不得显示对勾。
- OpenRouter 模型只能作为 OpenRouter provider/key 的当前模型写入 Codex；切换回 OpenAI OAuth 或非 OpenRouter Provider 时，`model` / `review_model` 必须恢复为 GPT 系列默认模型，不得把 `anthropic/...`、`openai/...` 等 provider-routed 模型继续保存在 `CodexBarGlobalSettings.defaultModel` 里。
- 切到 OpenRouter 前，`CodexSyncService` 必须把当前 OpenAI GPT `model` / `review_model` 保存到 `~/.codexbar/openai-model-state.json`；切回 OpenAI OAuth 或无默认模型的兼容 Provider 时优先从该独立状态文件恢复，不要依赖被 OpenRouter 覆盖后的 `~/.codex/config.toml`。
- OpenAI gateway / OpenRouter gateway 的 SSE 流式转发属于高频热路径；不要在每个字节上用 `Data.append(_:)` / `Data.range(of:)` 做事件边界扫描。优先复用共享的 `SSEEventStreamAccumulator` 或等价低分配缓冲逻辑，并同时覆盖 `\n\n` 与 `\r\n\r\n` 分隔。
- 菜单栏主面板中可点击元素必须有可见 hover 态，包括工具栏图标、Tab、账号组标题、成本卡片、账号行、Provider/OpenRouter 行、模型行和 Banner 操作按钮。
- 成本统计必须继续基于独立的本地 cost event ledger / usage event 链路计算，不得为了修正价格或展示问题重新依赖会话记录列表、历史会话快照或 `RecordsSnapshotService` 作为成本来源；价格表更新只改 `LocalCostPricing` 和对应成本测试。
- 成本统计刷新扫描 session JSONL 时必须优先复用 `SessionLogStore` 中 fingerprint 匹配且 usage summary 已完整解析的 `CachedSessionRecord`；未变化的历史 session 不得再次逐行 `enumerateLines` 解析。列表快照只读文件头生成的索引缓存不能当作完整成本缓存使用，必须保留显式完整性标记，避免把 usage event 链路误判为空。
- 成本统计的“今天”必须按当前本机时区自然日计算；`LocalCostSummary` 缓存跨过本机 0 点后不得继续作为有效 today 缓存展示，加载缓存时必须重新从 cost event ledger 汇总或交给既有刷新链路重算，避免继续展示昨天的 today 值。
- 状态栏图标的成本统计进行中动画由 `TokenStore.isRefreshingLocalCostSummaryInBackground` 驱动，并在 `MenuBarStatusItemController` 的 `NSStatusItem` 图像层绘制；不要用菜单栏 SwiftUI 面板内部状态推断后台成本统计是否正在进行，也不要让动画影响 popover 内容测量或高度锁定。
- 成本统计后台刷新状态必须由 `TokenStore` 的成本刷新状态机自洽关闭；pending 刷新请求交接、节流丢弃或最小间隔拦截时都不得让 `isRefreshingLocalCostSummaryInBackground` 残留为 true，否则状态栏动画会持续跑并造成高 CPU。菜单打开时即使强制刷新 OpenAI 账号用量，也不得顺带强制本地成本统计全量扫描 session；成本统计只应在无缓存、跨本机自然日过期或自身刷新间隔到期时运行。后续如果提供“关闭成本统计服务”的开关，也应先保持这条链路与 Wham 用量刷新、gateway、菜单内容测量解耦。
- OpenAI gateway 的 SSE/HTTP 响应转发真实运行路径必须使用 `URLSessionDataDelegate` 按网络 chunk 推送，不要退回 `URLSession.AsyncBytes` 逐字节读取；测试注入 `MockURLProtocol` 可保留兼容包装，但真实会话热路径不能重新引入 byte-by-byte async 循环。
- 任何改动这条链路的提交，都要一起检查 `codexBar/Services/TokenStore.swift`、`codexBar/Services/CodexSyncService.swift`、`codexBar/Services/OpenAIAccountGatewayService.swift`、`codexBar/Services/OpenRouterGatewayService.swift`、`codexBar/Views/MenuBarView.swift`、`codexBar/Views/Settings/SettingsWindowView.swift` 以及对应测试是否仍然同构。

## 本机构建交付

- 默认不要在任务完成后自动构建 `codexbar.app`。只有用户明确要求构建、安装、交付、发布，或本次任务本身就是修复构建/安装问题/修复重大bug时，才执行本机构建。
- “提交代码”不等于“构建交付”。除非用户明确要求，普通代码提交、PR 准备、评审修复或本地验证完成后，不递增 Build 号、不安装 `/Applications/codexbar.app`、不执行发布级清理。
- 如果本次任务需要产出本机可用的 `codexbar.app` 构建，在构建和必要测试通过后，必须把产物安装到本机供用户实际使用，默认目标为 `/Applications/codexbar.app`。
- 本机构建默认只构建当前机器可运行的架构版本，默认Debug构建，以提高构建效率；例如 Apple Silicon 本机使用 `ONLY_ACTIVE_ARCH=YES` 和 `ARCHS=arm64`。
- 每一次用于交付、安装、发布或让用户实际验证的构建，都必须递增 Xcode 的 `CURRENT_PROJECT_VERSION` Build 号，并在交付说明里同时报告版本号和 Build 号；不得只靠文件时间戳确认构建身份。
- 当判断本次修改有较大的功能变更时，才至少递增版本号 `1.x.x` 的最后一位；代码提交后，立刻递增版本号。
- 安装本机构建时不要主动退出、杀掉或重新打开正在运行的 `codexbar` 进程；直接覆盖目标安装副本即可，由用户手动重新打开新版本。
- 如果本机没有可用的开发者签名证书，可为本机实际使用采用 ad-hoc 签名；交付说明里要如实说明签名方式与验证结果。

## 本地安装清理

- 日常测试、构建验证、本地安装或中间迭代时，不要每次都做完整安装清理，避免重复清理拖慢反馈。
- 执行本机构建或安装时，只做保证 `/Applications/codexbar.app` 能被正确覆盖、签名校验能通过、用户重新打开后可正常运行的必要清理；例如移除本次覆盖目标中的损坏副本、清掉本次构建直接产生且会阻塞安装的临时 staging 目录。
- 单独要求“构建一下”“安装到本机”时，不默认扫描和清理 App Library、Spotlight、Launch Services、全量 DerivedData 或仓库外历史副本，除非这些残留已经明确影响本机正常运行。
- 只有在准备推送到远程仓库、创建远程 PR、发布 Release、上传/分发 `codexbar.app`，或用户明确要求完整清理时，才执行发布级完整安装清理。
- 发布级完整安装清理必须清理本次任务产生或显然属于构建/安装残留的 `codexbar.app` 副本与目录，例如仓库内 build/staging 目录、`DerivedData` 产物、`/private/tmp` 下的临时安装目录、临时挂载出的测试副本。
- 发布级完整安装清理必须核对最终可见性：`mdfind`、`lsregister` 或等价检查应只剩目标安装副本，通常是 `/Applications/codexbar.app`。
- 如果发布级清理后系统仍显示重复入口，代理必须继续清理 Launch Services / Spotlight 残留，直到重复入口消失或确认只剩用户明确保留的副本；清理过程不得主动退出、杀掉或重启正在运行的 `codexbar`。
- 不要擅自删除用户主动保存的归档、DMG、备份或仓库外长期保存副本；只有对临时构建产物和明确残留才默认清理。遇到非临时、非生成目录中的额外副本时，先说明再处理。

## Xcode 测试验证

- 这个仓库的测试 target / 模块名是 `codexbarTests`，不是 `codexBarTests`。用 `xcodebuild -only-testing` 跑指定测试时，过滤路径必须写成 `-only-testing:codexbarTests/...`；不要使用大小写不匹配的 `codexBarTests/...`，否则 Xcode 会报测试 target 不在当前 scheme / test plan 里。
- 如果 `-only-testing` 仍然报 scheme 或 test plan 找不到目标，先用 `xcodebuild -list` 和现有 scheme/test plan 配置确认可用测试目标，再调整验证命令；不要在未确认测试模块名和 scheme/test plan 的情况下反复重跑同一条错误命令。
- 涉及“今天”成本统计、跨本机自然日缓存失效、或 local day freshness 的测试，不要硬编码历史日期作为 today fixture；必须基于 `Calendar.current.startOfDay(for: Date())` 生成当前本机自然日内的时间戳，避免发布日跨天后测试稳定失败。

## 图标资产

- 当前正式 AppIcon 采用 `docs/assets/icon-exploration/2026-05-19-user-provided-icon.png` 作为源图；此前 Orbital Switch 只是探索稿，不再是正式图标来源。
- 只替换图标时，优先保持 `codexBar/Assets.xcassets/AppIcon.appiconset/Contents.json` 的文件名引用不变，覆盖对应 PNG 阶梯即可，避免牵连 Xcode 工程、Bundle ID、配置目录或更新源。

## 上下文压缩与断点恢复

- 发生上下文压缩、会话恢复、工具中断或长任务续接后，后续代理必须先核对压缩摘要、最近用户指令、当前工作区 diff、已运行命令和未完成验证，再判断断点状态；不要直接从头重新分析同一个问题。
- 恢复后必须先区分“已经完成并验证”“已经修改但未验证”“尚未开始”“被用户最新消息改变方向”的事项，再继续执行。最终回复要以最新用户消息为准，并明确哪些结论来自恢复前上下文、哪些是本轮重新验证得到的。
- 如果恢复摘要和当前文件状态冲突，以当前文件状态、`git status` / `git diff`、实际测试输出和用户最新指令为准；不要因为摘要里残留旧计划就重复实施已经完成的改动。

## Codex 输出要求

- 当前 `AGENTS.md` 会被 `.gitignore` 中的 `Agents.MD` 规则忽略，因此修改后不会出现在 `git status` 里，也不会默认被纳入提交。后续线程如果需要提交这份协作约定，必须先明确说明这一点，并按用户要求决定是否调整 ignore 规则或用强制添加方式处理。


每次完成任务后，请始终输出：

1. 修改了哪些文件
2. 每个文件的作用
3. 核心逻辑是如何实现的
4. 为什么这样实现
5. 我应该如何手动验证

如果没有运行测试或验证命令，也要明确说明。
当完成一个关键性改动后，往Agents.md中记录关键性改动的说明
