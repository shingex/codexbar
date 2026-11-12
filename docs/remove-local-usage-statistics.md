# 移除本机用量统计

本轮只使用上游接口返回的用量与额度。OpenAI OAuth、兼容 Provider、OpenRouter 和 OpenCode 的用量查询、余额／额度显示保留。

## 核心实现与原因

删除整条本机统计链路：session token 解析 → 用量事件与成本账本 → 定价估算 → 后台汇总／缓存 → 菜单和设置展示。同步移除其配置、测试替身和只服务于统计扫描避让的 gateway 活动追踪，避免仅隐藏界面后仍持续扫描或写账本。

记录页仍读取会话索引和消息，但不读取或汇总 token 用量。会话索引缓存使用 `records-session-cache.json`，与旧成本缓存分离。旧统计配置字段可以读取并被忽略，下一次常规保存不再写回这些已删除字段，其他配置继续保留。

未删除本机已有的旧缓存／账本文件，也未修改会话 JSONL、认证文件或正在运行的应用。

## 本轮文件及作用

此表只记录本轮修改；工作区原有路由、模型目录、工具历史兼容和视觉修改不属于本轮新增。

| 文件 | 本轮作用 |
| --- | --- |
| `codexBar/Models/LocalCostSummary.swift` | 删除本机成本与每日统计模型。 |
| `codexBar/Services/LocalCostSummaryService.swift` | 删除 session 用量汇总、定价和成本估算。 |
| `codexBar/Services/OpenCodeCostLedgerService.swift` | 删除 OpenCode 本机成本账本及读写。 |
| `codexBar/Views/CostSummaryRowView.swift` | 删除成本卡片、历史图表和成本详情。 |
| `codexBar/Services/TokenStore.swift` | 删除本机统计状态、启动加载、后台刷新、缓存和定价保存入口。 |
| `codexBar/Models/CodexBarConfig.swift` | 删除本机统计开关、卡片开关和自定义模型定价字段；旧字段由 Codable 忽略。 |
| `codexBar/Services/SettingsSaveRequestApplier.swift` | 删除统计开关和定价写入，保留接口用量显示方式与套餐排序参数。 |
| `codexBar/Services/SessionLogStore.swift` | 删除 token_count 解析、用量归并和事件账本；保留会话索引、消息、生命周期和删除。去重只按归档状态和时间选择记录。 |
| `codexBar/Services/CodexPaths.swift` | 删除成本缓存和账本路径；会话索引改用 records-session-cache.json。 |
| `codexBar/Services/RecordsSnapshotService.swift` | 删除记录中的 token 总量和按需读取接口。 |
| `codexBar/Services/OpenAIAccountGatewayService.swift` | 删除 OpenCode SSE 成本采集，以及只为本机统计避让使用的请求活动追踪；上游流直接交给原有转发／协议转换链路。 |
| `codexBar/Services/OpenRouterGatewayService.swift` | 删除只为本机统计避让使用的请求活动追踪。 |
| `codexBar/Models/MenuBarStatusItemPresentation.swift` | 删除本机金额回退和本地统计开关对接口配额显示的影响；无接口用量时使用现有 Provider 名称回退。 |
| `codexBar/Services/MenuBarStatusItemController.swift` | 删除本机统计刷新动画、计时器及订阅。 |
| `codexBar/Views/MenuBarView.swift` | 刷新按钮只执行接口用量查询，删除本机扫描和本机更新时间。 |
| `codexBar/Views/Settings/SettingsRecordsPage.swift` | 删除 token 信息块及其异步加载状态，保留会话选择和消息浏览。 |
| `codexBar/Views/Settings/SettingsWindowCoordinator.swift` | 删除定价草稿、历史定价模型列表和本机统计设置的协调逻辑。 |
| `codexBar/Views/Settings/SettingsWindowView.swift` | 删除本机统计卡片、定价编辑区及相关状态订阅。 |
| `codexBar/Localization.swift` | 删除成本、定价及本机 token 统计文案。 |
| `codexBarTests/LocalCostSummaryServiceTests.swift` | 删除已移除成本估算功能的测试。 |
| `codexBarTests/OpenCodeCostLedgerServiceTests.swift` | 删除已移除账本的测试。 |
| `codexBarTests/TokenStoreSettingsTests.swift` | 删除本机统计／定价测试和替身，新增旧统计配置字段被忽略且接口用量保留的回归用例。 |
| `codexBarTests/MenuBarStatusItemPresentationTests.swift` | 移除本机成本参数，验证接口用量与无接口数据时的名称回退。 |
| `codexBarTests/MenuBarRefreshPresentationTests.swift` | 刷新动画只跟随接口请求。 |
| `codexBarTests/MenuBarOpenRefreshGateTests.swift` | 删除本机自然日成本缓存测试，保留菜单打开刷新行为测试。 |
| `codexBarTests/MenuPanelPresentationTests.swift` | 删除成本详情渲染及统计开关，保留额度边界渲染。 |
| `codexBarTests/OpenAIAccountGatewayServiceTests.swift` | 删除本地成本账本测试，验证原生 OpenCode 响应中的 usage 继续转发。 |
| `codexBarTests/RecordsSnapshotServiceTests.swift` | 移除会话 token 字段，保留记录与模型摘要测试。 |
| `codexBarTests/SessionLogStoreRecordsSnapshotTests.swift` | 删除本地用量／定价扫描测试，保留记录缓存、索引和消息测试。 |
| `codexBarTests/SettingsRecordsViewModelTests.swift` | 删除 token 加载替身与断言，保留消息加载、会话选择和删除行为。 |
| `codexBarTests/SettingsWindowCoordinatorTests.swift` | 删除定价草稿测试及历史模型参数，保留设置保存、取消与路由行为。 |
| `codexBarTests/CodexBarConfigStoreTests.swift` | 移除已删除统计卡片开关的默认值断言。 |
| `codexBarTests/CodexBarBackupServiceTests.swift` | 用普通无关缓存验证备份范围，不再依赖已删除的成本路径常量。 |
| `codexBarTests/OpenAIRunningThreadAttributionServiceTests.swift` | 使用独立会话记录缓存路径，保留运行会话归属测试。 |
| `codexBarTests/CodexModelRoutingTests.swift` | 移除设置协调器的历史定价模型参数。 |
| `codexBarTests/KeyModelSelectionTests.swift` | 移除本机统计开关及无用途的请求活动替身方法。 |
| `codexBarTests/OpenAIOAuthRefreshServiceTests.swift` | 移除无用途的请求活动替身方法。 |
| `codexBarTests/TokenStoreGatewayLifecycleTests.swift` | 移除无用途的请求活动替身方法。 |
| `codexBarTests/WhamServiceTests.swift` | 移除无用途的请求活动替身方法。 |
| `README.md` | 中文说明改为接口配额与会话管理，删除本机成本功能说明。 |
| `README.en.md` | 同步英文功能说明。 |
| `AGENTS.md` | 更新当前架构与用量来源约定；保留其余已有项目约定。 |

## 手动验证

1. 下次正常构建运行后，打开菜单栏：只显示 OpenAI／Provider 接口配额或余额，不再出现本机今日／30 天／累计 token、金额或成本图表。
2. 点击刷新，检查 OAuth 配额与已配置 Provider 的接口数据仍能更新；在“设置 > 用量”修改剩余／已用显示方式并保存，确认两处显示一致。
3. 用没有配置用量接口的 Provider 检查菜单栏：显示现有名称回退，不显示本机估算金额。
4. 打开记录页并选择会话：列表、消息目录、复制恢复命令和归档筛选正常；不再显示或加载 token 总量。
5. 使用旧配置启动后再常规保存：账号、Key、路由及接口用量设置保留，不再写回已删除的统计／定价字段。

## 验证范围

不生成或安装 `.app`，不递增 Build。进行全部 Swift 生产源码与测试源码的语法及 Debug 类型检查，并检查补丁空白与残留引用。未执行 XCTest 运行和新版 GUI 验证。
