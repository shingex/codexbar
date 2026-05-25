import Foundation

/// Bilingual string helper — detects system language at runtime, with user override.
enum L {
    /// nil = follow system, true = force Chinese, false = force English
    nonisolated static var languageOverride: Bool? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "languageOverride") != nil else { return nil }
            return d.bool(forKey: "languageOverride")
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "languageOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "languageOverride")
            }
        }
    }

    nonisolated static var zh: Bool {
        if let override = languageOverride { return override }
        let lang = Locale.current.language.languageCode?.identifier ?? ""
        return lang.hasPrefix("zh")
    }

    // MARK: - Status Bar
    static var weeklyLimit: String { zh ? "周限额" : "Weekly Limit" }
    static var hourLimit: String   { zh ? "5h限额" : "5h Limit" }

    // MARK: - MenuBarView
    static var noAccounts: String      { zh ? "还没有账号"          : "No Accounts" }
    static var addAccountHint: String  { zh ? "点击下方 + 添加账号"   : "Tap + below to add an account" }
    static var refreshUsage: String    { zh ? "刷新用量"            : "Refresh Usage" }
    static var checkForUpdates: String { zh ? "检查更新"            : "Check for Updates" }
    static func menuUpdateAvailableTitle(_ version: String) -> String {
        zh ? "发现新版本 v\(version)" : "Version \(version) Is Available"
    }
    static func menuUpdateAvailableSubtitle(_ currentVersion: String, _ latestVersion: String) -> String {
        zh ? "当前为 \(currentVersion)，现在可以继续下载或安装 \(latestVersion)。" : "You're on \(currentVersion). Download or install \(latestVersion) now."
    }
    static var menuUpdateAction: String { zh ? "更新" : "Update" }
    static var addAccount: String      { zh ? "添加账号"            : "Add Account" }
    static var openAICSVToolbar: String { zh ? "导入或导出 OpenAI 账号" : "Import or Export OpenAI Accounts" }
    static func codexLaunchSwitchedInstanceStarted(_ account: String) -> String {
        zh ? "已切换到「\(account)」，并为该账号新开一个 Codex 实例。" : "Switched to \"\(account)\" and launched a new Codex instance for it."
    }
    static var codexLaunchProbeAppNotFound: String {
        zh ? "未找到 Codex.app" : "Codex.app was not found"
    }
    static var codexLaunchProbeExecutableMissing: String {
        zh ? "未找到 bundled codex 可执行文件" : "The bundled codex executable was not found"
    }
    static var codexLaunchProbeTimedOut: String {
        zh ? "启动 Codex.app 超时" : "Launching Codex.app timed out"
    }
    static func codexLaunchProbeFailed(_ message: String) -> String {
        zh
            ? "CodexBar 已尝试新开一个 Codex 实例，但 macOS 没有完成启动：\(message)。如果看到“等待子进程退出”，通常是旧 Codex 实例还在退出或系统还在处理启动锁；可以先关闭旧 Codex 后再试。"
            : "CodexBar tried to launch a new Codex instance, but macOS did not complete the launch: \(message). If the message says it is waiting for a child process to exit, the previous Codex instance is usually still shutting down or macOS is holding the launch lock; close the old Codex instance and try again."
    }
    static var exportOpenAICSVAction: String { zh ? "导出 OpenAI 账号" : "Export OpenAI Accounts" }
    static var importOpenAICSVAction: String { zh ? "导入 OpenAI 账号" : "Import OpenAI Accounts" }
    static var addOpenAIAccountMenu: String { zh ? "添加 OpenAI 账号" : "Add OpenAI Account" }
    static var settings: String { zh ? "设置" : "Settings" }
    static func updateInstallActionHelp(_ version: String) -> String {
        zh ? "下载或安装 \(version)" : "Download or Install \(version)"
    }
    static var updateInstallLocationOther: String {
        zh ? "非标准路径" : "Non-standard Location"
    }
    static var updateArchitectureUniversal: String {
        zh ? "通用构建" : "Universal Build"
    }
    static var updateSignatureUnknown: String {
        zh ? "未能读取应用签名信息" : "Unable to read the app signature"
    }
    static var updateBlockerGuidedDownloadOnlyRelease: String {
        zh ? "当前可用版本仍要求走引导下载/安装，不宣称自动替换闭环。" : "The current release still requires guided download/install instead of automatic replacement."
    }
    static func updateBlockerBootstrapRequired(_ currentVersion: String, _ minimumAutomaticVersion: String) -> String {
        zh
            ? "Bootstrap / Rollout Gate 未满足：\(currentVersion) 仍需先人工安装到 \(minimumAutomaticVersion) 或更高版本，自动更新闭环才从后续版本开始。"
            : "Bootstrap / rollout gate not satisfied: \(currentVersion) must first be manually upgraded to \(minimumAutomaticVersion) or later before automatic updates can be closed-loop."
    }
    static var updateBlockerAutomaticUpdaterUnavailable: String {
        zh ? "当前仓库尚未接入可用的成熟自动更新引擎。" : "A mature automatic update engine is not wired into this repository yet."
    }
    static func updateBlockerMissingTrustedSignature(_ summary: String) -> String {
        zh
            ? "当前安装缺少可用于成熟 updater 的可信签名：\(summary)"
            : "This installation lacks a trusted signature suitable for a mature updater: \(summary)"
    }
    static func updateBlockerGatekeeperAssessment(_ summary: String) -> String {
        zh
            ? "当前安装未通过 Gatekeeper / 分发前置条件：\(summary)"
            : "This installation does not satisfy the Gatekeeper / distribution prerequisites: \(summary)"
    }
    static func updateBlockerUnsupportedInstallLocation(_ pathDescription: String) -> String {
        zh
            ? "当前安装路径为 \(pathDescription)，尚未纳入可自动替换的受支持范围。"
            : "The current install location is \(pathDescription), which is not yet in the supported auto-replace matrix."
    }
    static var updateErrorMissingReleasesURL: String {
        zh ? "未配置 GitHub Releases API 地址。" : "The GitHub Releases API URL is not configured."
    }
    static func updateErrorInvalidCurrentVersion(_ version: String) -> String {
        zh ? "当前版本号无效：\(version)" : "Invalid current version: \(version)"
    }
    static func updateErrorInvalidReleaseVersion(_ version: String) -> String {
        zh ? "最新稳定版本号无效：\(version)" : "Invalid latest stable version: \(version)"
    }
    static var updateErrorInvalidResponse: String {
        zh ? "GitHub Releases 响应无效。" : "The GitHub Releases response is invalid."
    }
    static func updateErrorUnexpectedStatusCode(_ statusCode: Int) -> String {
        zh ? "GitHub Releases API 返回异常状态码：\(statusCode)" : "The GitHub Releases API returned status code \(statusCode)."
    }
    static var updateErrorNoInstallableStableRelease: String {
        zh ? "GitHub Releases 中未找到可安装的正式稳定版本。" : "No installable stable release was found on GitHub Releases."
    }
    static func updateErrorNoCompatibleArtifact(_ architecture: String) -> String {
        zh ? "最新稳定版本中缺少适用于 \(architecture) 的安装包。" : "The latest stable release does not contain a compatible installer for \(architecture)."
    }
    static func updateErrorFailedToOpenDownloadURL(_ url: String) -> String {
        zh ? "无法打开下载链接：\(url)" : "Failed to open the download URL: \(url)"
    }
    static var updateErrorAutomaticUpdateUnavailable: String {
        zh ? "当前构建尚未接入可执行的自动更新引擎。" : "An executable automatic update engine is not available in this build."
    }
    static var settingsWindowTitle: String { self.settings }
    static var settingsWindowHint: String {
        zh
            ? "左侧切换账户、记录、用量和更新设置。账户/用量修改会先保存在草稿里；记录页只负责浏览与刷新，不进入 Save / Cancel 草稿流。"
            : "Use the sidebar to switch between account, records, usage, and update settings. Account and usage changes stay in a draft; the records page is browse/refresh only and does not participate in Save or Cancel."
    }
    static var settingsAccountsPageTitle: String { zh ? "常规" : "General" }
    static var settingsGettingStartedPageTitle: String { zh ? "开始使用" : "Getting Started" }
    static var settingsBackupPageTitle: String { zh ? "备份" : "Backup" }
    static var settingsRecordsPageTitle: String { zh ? "记录" : "Records" }
    static var settingsUsagePageTitle: String { zh ? "用量" : "Usage" }
    static var settingsCodexAppPathPageTitle: String { zh ? "Codex App 路径设置" : "Codex App Path" }
    static var settingsUpdatesPageTitle: String { zh ? "更新" : "Updates" }
    static var settingsUpdatesPageHint: String {
        zh
            ? "从这里检查 GitHub Releases 上首个可安装的正式稳定版本，并继续下载或安装当前可用更新。"
            : "Check the first installable stable release on GitHub Releases here, then continue to download or install the current update."
    }
    static var settingsUpdatesCurrentVersionTitle: String { zh ? "当前版本" : "Current Version" }
    static var settingsUpdatesLatestVersionTitle: String { zh ? "GitHub 最新稳定版本" : "Latest Stable Version on GitHub" }
    static var settingsUpdatesStatusTitle: String { zh ? "更新状态" : "Update Status" }
    static var settingsUpdatesUnknownVersion: String { zh ? "尚未检查" : "Not Checked Yet" }
    static var settingsUpdatesCheckAction: String { zh ? "检查 GitHub 上的最新稳定版本" : "Check the Latest Stable Version on GitHub" }
    static var settingsUpdatesInstallAction: String { zh ? "继续下载或安装更新" : "Continue Download or Install" }
    static var settingsUpdatesChecking: String { zh ? "正在检查 GitHub 上的最新稳定版本…" : "Checking the latest stable version on GitHub..." }
    static var settingsUpdatesIdle: String { zh ? "尚未发起更新检查。" : "No update check has been started yet." }
    static var settingsUpdatesSourceNote: String {
        zh
            ? "运行时会扫描 GitHub Releases 列表，只认非 draft、非 prerelease、且带 dmg/zip 安装包的正式 release。"
            : "Runtime checks scan the GitHub Releases list and only accept non-draft, non-prerelease releases that ship installable dmg/zip assets."
    }
    static var settingsUpdatesReissueLimitNote: String {
        zh
            ? "如果你已安装首发 1.1.9，同版本重发不会自动显示为可升级；需要手工下载重发 build。"
            : "If you already installed the first 1.1.9 build, a same-version reissue will not show up as an upgrade automatically; you must download the reissued build manually."
    }
    static func settingsUpdatesUpToDate(_ version: String) -> String {
        zh ? "当前版本 \(version) 已与 GitHub 上的最新稳定版本一致。" : "The current version \(version) already matches the latest stable version on GitHub."
    }
    static func settingsUpdatesAvailable(_ currentVersion: String, _ latestVersion: String) -> String {
        zh ? "当前版本 \(currentVersion)，GitHub 上可用最新稳定版本 \(latestVersion)。" : "Current version \(currentVersion); the latest stable version on GitHub is \(latestVersion)."
    }
    static func settingsUpdatesExecuting(_ version: String) -> String {
        zh ? "正在处理 \(version) 的更新动作。" : "Processing the update action for \(version)."
    }
    static func settingsUpdatesFailed(_ message: String) -> String {
        zh ? "更新失败：\(message)" : "Update failed: \(message)"
    }
    static var backupPageHint: String {
        zh
            ? "备份 CodexBar 的设置、账号信息及 Codex 配置，便于恢复或在其他设备上使用。"
            : "Back up CodexBar settings, account information, and Codex configuration for restore or use on another device."
    }
    static var backupCodexBarCardTitle: String {
        zh ? "备份 CodexBar 设置与账号信息" : "Back Up CodexBar Settings and Accounts"
    }
    static var backupCodexCardTitle: String {
        zh ? "备份 Codex 配置文件" : "Back Up Codex Configuration Files"
    }
    static var backupIncludedContentTitle: String { zh ? "包含内容" : "Included Content" }
    static var backupIncludedFilesTitle: String { zh ? "包含文件" : "Included Files" }
    static var backupCodexBarContentAppSettings: String {
        zh ? "应用设置（通用、外观、快捷键等）" : "App settings (general, appearance, shortcuts, and more)"
    }
    static var backupCodexBarContentAccounts: String {
        zh ? "账号信息（OpenAI、第三方 API 等）" : "Account information (OpenAI, third-party APIs, and more)"
    }
    static var backupCodexContentAuth: String {
        zh ? "auth.json（认证配置）" : "auth.json (authentication configuration)"
    }
    static var backupCodexContentConfig: String {
        zh ? "config.toml（Codex 配置）" : "config.toml (Codex configuration)"
    }
    static var backupLastBackupLabel: String { zh ? "上次备份：" : "Last backup:" }
    static var backupNeverBackedUp: String { zh ? "尚未备份" : "Never" }
    static var backupDetailsAction: String { zh ? "查看详情" : "View Details" }
    static var backupNowAction: String { zh ? "立即备份" : "Back Up Now" }
    static var backupRestoreAction: String { zh ? "选择备份文件恢复" : "Restore from Backup File" }
    static var backupCodexBarFooter: String {
        zh ? "备份文件仅保存在本地，不会上传到任何服务器。" : "Backup files are stored only on this Mac and are not uploaded to any server."
    }
    static var backupCodexFooter: String {
        zh ? "此备份仅包含 Codex 配置文件，不包含 CodexBar 应用设置与账号信息。" : "This backup only contains Codex configuration files, not CodexBar app settings or account information."
    }
    static var backupManagementTitle: String { zh ? "备份管理" : "Backup Management" }
    static var backupManagementHint: String {
        zh ? "管理已有的备份文件，查看详情或删除不需要的备份。" : "Manage existing backup files, view details, or delete backups you no longer need."
    }
    static var backupManageFilesAction: String { zh ? "管理备份文件" : "Manage Backup Files" }
    static var backupSucceededAccessibilityLabel: String { zh ? "备份成功" : "Backup succeeded" }
    static func backupRestorePanelTitle(_ kind: String) -> String {
        zh ? "选择\(kind)备份文件" : "Choose \(kind) Backup File"
    }
    static var backupRestorePanelPrompt: String { zh ? "恢复" : "Restore" }
    static func backupErrorEmpty(_ kind: String) -> String {
        zh ? "没有可备份的\(kind)文件。" : "There are no \(kind) files to back up."
    }
    static var backupErrorInvalidFormat: String {
        zh ? "备份文件格式无效。" : "The backup file format is invalid."
    }
    static func backupErrorUnexpectedKind(_ expected: String, _ actual: String) -> String {
        zh ? "备份类型不匹配：需要 \(expected)，实际为 \(actual)。" : "Backup type mismatch: expected \(expected), got \(actual)."
    }
    static func backupErrorUnknownPath(_ path: String) -> String {
        zh ? "备份文件包含未知路径：\(path)" : "The backup contains an unknown path: \(path)"
    }
    static func backupErrorUnsafePath(_ path: String) -> String {
        zh ? "备份文件包含不安全路径：\(path)" : "The backup contains an unsafe path: \(path)"
    }
    static func backupErrorInvalidFileData(_ path: String) -> String {
        zh ? "备份文件内容无效：\(path)" : "The backup contains invalid file data: \(path)"
    }
    static var settingsRecordsPageHint: String {
        zh
            ? "记录页暂时只管理 Codex 本机会话。右侧默认显示对话目录；点击目录条目后再展开具体消息。"
            : "Records currently manages local Codex sessions only. The right side shows the conversation directory by default; click an item to expand the message."
    }
    static var settingsRecordsSearchPlaceholder: String { zh ? "搜索标题、目录、session ID 或 model" : "Search title, directory, session ID, or model" }
    static var settingsRecordsRefreshAction: String { zh ? "全量刷新" : "Refresh All" }
    static var settingsRecordsGoToUsageAction: String { zh ? "去用量页编辑价格" : "Open Usage to Edit Pricing" }
    static var settingsRecordsLoading: String { zh ? "正在加载记录…" : "Loading records..." }
    static var settingsRecordsRefreshingIncremental: String { zh ? "正在增量刷新记录…" : "Refreshing records incrementally..." }
    static var settingsRecordsCachedRefreshing: String {
        zh ? "已显示缓存，正在检查新增或变更记录…" : "Showing cached records. Checking for new or changed records..."
    }
    static var settingsRecordsRefreshingAll: String { zh ? "正在全量刷新记录…" : "Refreshing all records..." }
    static var settingsRecordsIdle: String { zh ? "尚未加载记录。" : "Records have not been loaded yet." }
    static func settingsRecordsLastUpdated(_ text: String) -> String {
        zh ? "最近更新：\(text)" : "Last updated: \(text)"
    }
    static func settingsRecordsRefreshFailedKeepingList(_ text: String) -> String {
        zh ? "刷新失败：\(text)（已保留当前列表）" : "Refresh failed: \(text) (kept the current list)"
    }
    static var settingsRecordsRefreshTimeout: String {
        zh ? "全量刷新超时，旧快照已保留。" : "The full refresh timed out. The previous snapshot was kept."
    }
    static var settingsRecordsRetryAction: String { zh ? "重试加载" : "Retry" }
    static var settingsRecordsEmptyState: String {
        zh ? "还没有可显示的 records 快照。你可以稍后重试，或直接触发一次全量刷新。" : "There is no records snapshot to show yet. Retry later or trigger a full refresh."
    }
    static var settingsRecordsSessionsMetric: String { zh ? "会话" : "Sessions" }
    static var settingsRecordsModelsMetric: String { zh ? "模型" : "Models" }
    static var settingsRecordsArchivedMetric: String { zh ? "已归档" : "Archived" }
    static var settingsRecordsAllResults: String { zh ? "当前显示全部结果" : "Showing all results" }
    static func settingsRecordsFilteredResults(_ visible: Int, total: Int) -> String {
        zh ? "已筛出 \(visible) / \(total)" : "Filtered \(visible) / \(total)"
    }
    static var settingsRecordsActiveModelsFootnote: String {
        zh ? "按当前筛选显示的模型数" : "Models visible in the current filter"
    }
    static func settingsRecordsActiveArchivedFootnote(_ activeCount: Int) -> String {
        zh ? "当前活跃 \(activeCount)" : "Active now: \(activeCount)"
    }
    static var settingsRecordsSessionsTitle: String { zh ? "Codex 会话" : "Codex Sessions" }
    static var settingsRecordsSessionsHint: String {
        zh ? "主视图按最近活动时间倒序展示 session 记录；列表只消费单个完整 snapshot。" : "Primary view sorted by latest activity descending. The list always renders from one complete snapshot."
    }
    static var settingsRecordsSessionsEmpty: String {
        zh ? "当前没有会话记录。" : "There are no session records yet."
    }
    static var settingsRecordsSessionsLoadingCompact: String {
        zh ? "正在读取记录…" : "Reading records..."
    }
    static var settingsRecordsNoSearchResults: String {
        zh ? "当前筛选没有匹配到会话。" : "No sessions match the current filter."
    }
    static var settingsRecordsStatusFilterAll: String { zh ? "全部" : "All" }
    static var settingsRecordsStatusFilterActive: String { zh ? "活跃" : "Active" }
    static var settingsRecordsStatusFilterArchived: String { zh ? "已归档" : "Archived" }
    static var settingsRecordsStatusFilterHelp: String {
        zh ? "按会话状态筛选" : "Filter sessions by status"
    }
    static var settingsRecordsArchivedBadge: String { zh ? "已归档" : "Archived" }
    static var settingsRecordsActiveBadge: String { zh ? "活跃" : "Active" }
    static var settingsRecordsCurrentBadge: String { zh ? "当前" : "Current" }
    static var settingsRecordsStartedAtTitle: String { zh ? "开始时间" : "Started" }
    static var settingsRecordsLastActivityTitle: String { zh ? "最后活动" : "Last Activity" }
    static var settingsRecordsTotalTokensTitle: String { zh ? "总 Token" : "Total Tokens" }
    static var settingsRecordsModelTitle: String { zh ? "模型" : "Model" }
    static var settingsRecordsDirectoryTitle: String { zh ? "对话目录" : "Conversation Directory" }
    static var settingsRecordsUserMessageTitle: String { zh ? "用户消息" : "User Message" }
    static var settingsRecordsToolMessageTitle: String { zh ? "工具输出" : "Tool Output" }
    static var settingsRecordsCopyCommandAction: String { zh ? "复制命令" : "Copy Command" }
    static var settingsRecordsDeleteAction: String { zh ? "删除" : "Delete" }
    static var settingsRecordsCopyMessageAction: String { zh ? "复制消息" : "Copy Message" }
    static var settingsRecordsBatchAction: String { zh ? "批量管理" : "Batch" }
    static var settingsRecordsExitBatchAction: String { zh ? "退出批量" : "Exit Batch" }
    static var settingsRecordsSelectAllAction: String { zh ? "全选当前" : "Select All" }
    static func settingsRecordsDeleteSelectedAction(_ count: Int) -> String {
        zh ? "删除已选 \(count)" : "Delete \(count)"
    }
    static var settingsRecordsSelectSession: String { zh ? "请选择左侧会话。" : "Select a session from the left." }
    static var settingsRecordsDetailWindowTitle: String { zh ? "会话详情" : "Session Detail" }
    static var settingsRecordsConversationEmpty: String { zh ? "这个会话没有可显示的用户消息目录。" : "This session has no user-message directory to show." }
    static var settingsRecordsDeleteFailed: String { zh ? "删除会话失败。" : "Failed to delete the session." }
    static var settingsRecordsDeleteConfirmTitle: String { zh ? "确认删除会话？" : "Delete session?" }
    static var settingsRecordsDeleteBatchConfirmTitle: String { zh ? "确认删除所选会话？" : "Delete selected sessions?" }
    static func settingsRecordsDeleteConfirmMessage(_ title: String) -> String {
        zh ? "将删除「\(title)」的本地记录文件，此操作不可撤销。" : "This will delete the local record file for \"\(title)\". This cannot be undone."
    }
    static func settingsRecordsDeleteBatchConfirmMessage(_ count: Int) -> String {
        zh ? "将删除 \(count) 个本地会话记录文件，此操作不可撤销。" : "This will delete \(count) local session record files. This cannot be undone."
    }
    static var settingsRecordsModelsTitle: String { zh ? "Models 摘要" : "Models Summary" }
    static var settingsRecordsModelsHint: String {
        zh ? "辅区按最近使用时间展示模型摘要；model pricing 仍在 Usage 页编辑。" : "Secondary summary of models sorted by recent usage. Model pricing stays on the Usage page."
    }
    static var settingsRecordsModelsEmpty: String {
        zh ? "当前没有可显示的模型摘要。" : "There are no models to summarize yet."
    }
    static func settingsRecordsModelSummary(_ sessionCount: Int) -> String {
        zh ? "\(sessionCount) 个 session" : "\(sessionCount) sessions"
    }
    static func settingsRecordsWarningsTitle(_ count: Int) -> String {
        zh ? "读取告警（\(count)）" : "Warnings (\(count))"
    }
    static var settingsRecordsWarningsHint: String {
        zh ? "只有数据层返回的告警会显示在这里；UI 不会自行拼接额外 warning。" : "Only warnings returned by the data layer appear here; the UI does not synthesize extra warnings."
    }
    static var usageDisplayModeTitle: String { zh ? "用量显示方式" : "Usage Display" }
    static var remainingUsageDisplay: String { zh ? "剩余用量" : "Remaining Quota" }
    static var usedQuotaDisplay: String { zh ? "已用额度" : "Used Quota" }
    static var remainingShort: String { zh ? "剩余" : "Remaining" }
    static var usedShort: String { zh ? "已用" : "Used" }
    static var localCostTitle: String { zh ? "成本" : "Cost" }
    static var localCostToday: String { zh ? "今日" : "Today" }
    static var localCostLast30Days: String { zh ? "近 30 天" : "Last 30 Days" }
    static var localCostAllTime: String { zh ? "累计" : "All-Time" }
    static var localCostNoHistory: String { zh ? "暂无成本历史数据。" : "No cost history data." }
    static func localCostTokens(_ tokens: String) -> String {
        zh ? "\(tokens) Token" : "\(tokens) tokens"
    }
    static var quotaSortSettingsTitle: String { zh ? "用量排序参数" : "Quota Sort Parameters" }
    static var quotaSortSettingsHint: String {
        zh
            ? "排序仍按用量规则计算，正在使用和运行中的账号优先。这里仅调整套餐权重换算：默认 free=1、plus=10、pro=plus×10（可调 5 到 30）、team=plus×1.5。"
            : "Sorting still follows quota usage rules, with active and running accounts first. These controls only adjust plan weighting: by default free=1, plus=10, pro=plus×10 (adjustable from 5 to 30), and team=plus×1.5."
    }
    static var modelPricingSectionTitle: String { zh ? "历史模型价格" : "Historical Model Pricing" }
    static var modelPricingSectionHint: String {
        zh
            ? "价格只用于本地 session 成本估算。token 统计始终来自本地 session，口径固定为 input + cached input + output；未配置价格的模型默认按 0 处理。"
            : "Pricing is only used for local session cost estimates. Token counts always come from local sessions using input + cached input + output, and models without pricing default to 0."
    }
    static var modelPricingSectionEmpty: String {
        zh ? "还没有从本地 session 里提取到历史模型。" : "No historical models have been extracted from local sessions yet."
    }
    static var modelPricingInputTitle: String { zh ? "Input 单价" : "Input Price" }
    static var modelPricingCachedInputTitle: String { zh ? "Cached Input 单价" : "Cached Input Price" }
    static var modelPricingOutputTitle: String { zh ? "Output 单价" : "Output Price" }
    static var quotaSortPlusWeightTitle: String { zh ? "Plus 相对 Free 权重" : "Plus Weight vs Free" }
    static var quotaSortProRatioTitle: String { zh ? "Pro 相对 Plus 倍数" : "Pro Ratio vs Plus" }
    static var quotaSortTeamRatioTitle: String { zh ? "Team 相对 Plus 倍数" : "Team Ratio vs Plus" }
    static var accountUsageModeTitle: String { zh ? "账号使用模式" : "Account Usage Mode" }
    static var accountUsageModeHint: String {
        zh
            ? "切换和聚合只管理 OpenAI OAuth 账号；混合模式才会保留 OAuth 登录态，同时把请求目标手动指向 Provider 或 OpenRouter。"
            : "Switch and Aggregate only manage OpenAI OAuth accounts. Hybrid keeps the OAuth login while manually routing requests to a provider or OpenRouter."
    }
    static var accountUsageModeAggregate: String { zh ? "聚合网关" : "Aggregate Gateway" }
    static var providerUsageSectionTitle: String { zh ? "Provider 用量配置" : "Provider Usage Configuration" }
    static var providerUsageSectionHint: String {
        zh
            ? "为 Provider 添加用量统计接口后，可获取当前日 / 周 / 月的用量 ($)、限额 ($) 及百分比 (%)。"
            : "Add a provider usage API to fetch day / week / month usage ($), limits ($), and percentages (%)."
    }
    static var providerUsageEmptyTitle: String { zh ? "暂无用量统计" : "No usage statistics" }
    static var providerUsageAddAPI: String { zh ? "添加接口" : "Add API" }
    static var providerUsageRefresh: String { zh ? "刷新" : "Refresh" }
    static var providerUsageMore: String { zh ? "更多" : "More" }
    static var providerUsageEditAPI: String { zh ? "编辑用量接口" : "Edit usage API" }
    static var providerUsageDisableAPI: String { zh ? "禁用用量接口" : "Disable usage API" }
    static var providerUsageViewRawResponse: String { zh ? "查看原始响应 / 调试" : "View raw response / Debug" }
    static var providerUsageURLLabel: String { zh ? "请求地址" : "Request URL" }
    static var providerUsageURLPlaceholder: String { zh ? "为空时使用 Provider baseUrl + /v1/usage" : "Defaults to provider baseUrl + /v1/usage" }
    static var providerUsageTimeoutLabel: String { zh ? "超时时间（秒）" : "Timeout (seconds)" }
    static var providerUsageIntervalLabel: String { zh ? "自动查询间隔（分钟）" : "Auto refresh interval (minutes)" }
    static var providerUsageMethodLabel: String { zh ? "请求方法" : "Method" }
    static var providerUsageHeadersLabel: String { zh ? "默认 Header" : "Default Headers" }
    static var providerUsageSave: String { zh ? "保存接口" : "Save API" }
    static var providerUsageCancel: String { cancel }
    static var providerUsageDaily: String { zh ? "今日" : "Today" }
    static var providerUsageWeekly: String { zh ? "本周" : "This Week" }
    static var providerUsageMonthly: String { zh ? "本月" : "This Month" }
    static var providerUsageTodayRemaining: String { zh ? "今日剩余" : "Today Remaining" }
    static var providerUsageTodayUsed: String { zh ? "今日已用" : "Today Used" }
    static var providerUsageWeeklyRemaining: String { zh ? "本周剩余" : "This Week Remaining" }
    static var providerUsageWeeklyUsed: String { zh ? "本周已用" : "This Week Used" }
    static var providerUsageMonthlyRemaining: String { zh ? "本月剩余" : "This Month Remaining" }
    static var providerUsageMonthlyUsed: String { zh ? "本月已用" : "This Month Used" }
    static var providerUsageRemainingRatio: String { zh ? "剩余比例" : "Remaining Ratio" }
    static var providerUsageUsedRatio: String { zh ? "已用比例" : "Used Ratio" }
    static var providerUsageSharedPlan: String { zh ? "共享套餐" : "Shared Plan" }
    static var providerUsageTotal: String { zh ? "总用量" : "Total" }
    static var providerUsageUsed: String { zh ? "已用" : "Used" }
    static var providerUsageRemaining: String { zh ? "剩余" : "Remaining" }
    static var providerUsageLimit: String { zh ? "限额" : "Limit" }
    static var providerUsageUnlimited: String { zh ? "无限制" : "Unlimited" }
    static var providerUsageNoData: String { zh ? "暂无数据" : "No data" }
    static var providerUsageNeverUpdated: String { zh ? "尚未刷新" : "Never refreshed" }
    static var providerUsageLastUpdated: String { zh ? "更新于" : "Updated" }
    static var providerUsagePlan: String { zh ? "套餐" : "Plan" }
    static var providerUsageExpires: String { zh ? "到期" : "Expires" }
    static var providerUsageValid: String { zh ? "有效" : "Valid" }
    static var providerUsageInvalid: String { zh ? "无效" : "Invalid" }
    static var providerUsageDisableLocalStatsTitle: String { zh ? "禁用本地统计" : "Disable Local Statistics" }
    static var providerUsageDisableLocalStatsHint: String {
        zh
            ? "您已经设置用量接口，禁用本地统计，可以节省系统资源"
            : "You have configured a usage API. Disabling local statistics can save system resources."
    }
    static var accountUsageModeAggregateShort: String { zh ? "聚合" : "Aggregate" }
    static var accountUsageModeAggregateHint: String {
        zh
            ? "只把 OpenAI OAuth 账号当成本地账号池。Provider 和 OpenRouter 不参与聚合，也不会作为失败兜底。"
            : "Only OpenAI OAuth accounts are treated as a local pool. Providers and OpenRouter do not join aggregation or fallback."
    }
    static var accountUsageModeHybrid: String { zh ? "混合模式" : "Hybrid" }
    static var accountUsageModeHybridShort: String { zh ? "混合" : "Hybrid" }
    static var accountUsageModeHybridHint: String {
        zh
            ? "保留 OpenAI OAuth 账号作为登录态；菜单里点 Provider/OpenRouter 的使用只会设置请求目标。失败会原样返回，不自动切换。"
            : "Keep an OpenAI OAuth account as the login identity. Using a provider/OpenRouter only sets the request target. Failures are returned as-is without automatic switching."
    }
    static var accountUsageModeSwitch: String { zh ? "手动模式" : "Manual Mode" }
    static var accountUsageModeSwitchShort: String { zh ? "手动" : "Manual" }
    static var accountUsageModeSwitchHint: String {
        zh
            ? "保持当前行为：手动点账号后才切换，Codex 直接使用那个账号写入的 auth/config。"
            : "Keep the current behavior: switching only happens when you explicitly choose an account, and Codex uses that account's synced auth/config directly."
    }
    static var openAIAccountSwitchAction: String { zh ? "切换" : "Switch" }
    static var openAIAccountUseAction: String { zh ? "使用" : "Use" }
    static var providerUseAction: String { zh ? "使用" : "Use" }
    static var settingsDraftCurrentTarget: String { zh ? "保存后使用" : "Use After Save" }
    static var gettingStartedModeTitle: String { zh ? "模式选择" : "Mode" }
    static var gettingStartedRecommendedSuffix: String { zh ? "（推荐）" : " (Recommended)" }
    static var gettingStartedModeSwitchTitle: String { zh ? "手动模式" : "Manual Mode" }
    static var gettingStartedModeSwitchDetail: String {
        zh
            ? "选中哪个账号用哪个账号；使用第三方中转站 API 时无法使用所有官方插件和远程控制等功能"
            : "Use the selected account directly. Third-party relay APIs cannot use all official plugins or remote-control features."
    }
    static var gettingStartedModeAggregateTitle: String { zh ? "聚合网关" : "Aggregate Gateway" }
    static var gettingStartedModeAggregateDetail: String {
        zh
            ? "把多个 OpenAI 账号当成本地账号池，不适用于中转站 API"
            : "Treat multiple OpenAI accounts as a local pool. This does not apply to relay APIs."
    }
    static var gettingStartedModeHybridTitle: String { zh ? "混合路由" : "Hybrid Routing" }
    static var gettingStartedModeHybridDetail: String {
        zh
            ? "保持 OpenAI 账号登录，同时使用选中的中转站 API，可以正常使用插件及远程控制等功能"
            : "Keep OpenAI login while routing requests through the selected relay API, preserving plugins and remote-control features."
    }
    static var gettingStartedRequirementTitle: String {
        zh
            ? "完成基础设置"
            : "Finish setup"
    }
    static var gettingStartedRequirementCompletedTitle: String {
        zh ? "基础设置已完成" : "Setup completed"
    }
    static func gettingStartedRequirementDetail(for mode: CodexBarOpenAIAccountUsageMode) -> String {
        switch mode {
        case .switchAccount:
            return zh ? "添加任意两个账号，即可体验完整功能" : "Add any two accounts to unlock the full setup."
        case .hybridProvider:
            return zh ? "关联 OpenAI 账号，并添加一个第三方 API，即可体验完整功能" : "Connect an OpenAI account and add a third-party API to unlock the full setup."
        case .aggregateGateway:
            return zh ? "关联至少 2 个 OpenAI 账号，即可体验聚合功能" : "Connect at least two OpenAI accounts to use aggregation."
        }
    }
    static func gettingStartedRequirementCompletedDetail(for modeTitle: String) -> String {
        zh ? "你现在可以使用「\(modeTitle)」的完整功能" : "You can now use the full \(modeTitle) experience."
    }
    static var gettingStartedRequirementOpenAIShort: String {
        zh ? "OpenAI" : "OpenAI"
    }
    static var gettingStartedRequirementThirdPartyShort: String {
        zh ? "第三方 API" : "Third-party API"
    }
    static var gettingStartedRequirementAnyAccountShort: String {
        zh ? "任意账号" : "Any account"
    }
    static func gettingStartedRequirementStepProgress(_ completed: Int, _ required: Int, _ label: String) -> String {
        zh ? "\(label) \(completed)/\(required)" : "\(label) \(completed)/\(required)"
    }
    static var gettingStartedPrivacyNote: String {
        zh
            ? "所有账号信息和 API key 均只保存在你的本地，请放心使用。"
            : "All account information and API keys are stored only on this Mac."
    }
    static var gettingStartedOpenAISectionTitle: String { zh ? "1. 关联 OpenAI 账号" : "1. Connect an OpenAI Account" }
    static var gettingStartedOpenAIEmptyTitle: String { zh ? "尚未添加" : "Not Added Yet" }
    static var gettingStartedOpenAIEmptyDetail: String {
        zh ? "添加你的第一个 OpenAI 账号以开始使用" : "Add your first OpenAI account to start."
    }
    static var gettingStartedOpenAIAuthActionTitle: String {
        zh ? "方式 1：通过 OpenAI 官方网站进行在线认证" : "Method 1: Authenticate on the OpenAI website"
    }
    static var gettingStartedOpenAIAuthActionDetail: String { "" }
    static var gettingStartedOpenAIAuthButton: String { zh ? "在线认证" : "Authenticate" }
    static var gettingStartedOpenAIImportActionTitle: String {
        zh ? "方式 2：如果 Codex 已经登录，也可以直接导入 auth.json 文件进行关联" : "Method 2: Import auth.json if Codex is already logged in"
    }
    static var gettingStartedOpenAIImportActionDetail: String { "" }
    static var gettingStartedOpenAIImportButton: String { zh ? "导入" : "Import" }
    static var gettingStartedProviderSectionTitle: String {
        zh ? "2. 添加中转站或者 OpenRouter 的 API key" : "2. Add a Relay or OpenRouter API Key"
    }
    static var gettingStartedProviderEmptyTitle: String { zh ? "尚未添加" : "Not Added Yet" }
    static var gettingStartedProviderEmptyDetail: String {
        zh ? "添加 API key 以启用第三方转发服务" : "Add an API key to enable third-party routing."
    }
    static var openAIAggregateEnableAction: String { zh ? "启用聚合" : "Enable Aggregate" }
    static var openAIAggregateEnabledAction: String { zh ? "已启用" : "Enabled" }
    static var openAIAggregatePanelTitle: String { zh ? "OpenAI 聚合账号池" : "OpenAI Aggregate Pool" }
    static var openAIAggregatePanelHint: String {
        zh
            ? "所有当前可用的 OAuth 账号会自动参与聚合；这里不会修改 Provider 或 OpenRouter。"
            : "All currently usable OAuth accounts join aggregation automatically. Providers and OpenRouter are not changed here."
    }
    static var openAIHybridPanelTitle: String { zh ? "混合请求目标" : "Hybrid Request Target" }
    static var openAIHybridPanelHint: String {
        zh
            ? "OAuth 账号只保留登录身份；刷新时间跟随上方成本统计的刷新时间，Provider/OpenRouter 只决定请求去向。"
            : "OAuth accounts only keep the login identity. The refresh time follows the cost summary above; providers/OpenRouter only decide where requests go."
    }
    static var openAIHybridOAuthTitle: String { zh ? "OAuth 登录身份" : "OAuth Login" }
    static var openAIHybridTargetsTitle: String { "Provider" }
    static var openAIHybridNoTargets: String { zh ? "还没有可用 Provider 或 OpenRouter Key。" : "No provider or OpenRouter key target is available yet." }
    static var openAIHybridOAuthAccountsHint: String {
        zh
            ? "这些 OAuth 账号仍用于登录态和额度展示；在混合模式里点击账号会回到原生 OAuth 请求，不经过 Provider Gateway。"
            : "These OAuth accounts still provide login identity and quota display. Choosing an account in Hybrid returns to native OAuth requests without provider gateway routing."
    }
    static var openAIHybridCurrentOAuthHint: String {
        zh
            ? "切换到当前 OAuth 会回到原生 OAuth 请求，不经过 Gateway。"
            : "Switching to the current OAuth target returns to native OAuth requests without Gateway routing."
    }
    static func quotaSortPlusWeightValue(_ value: Double) -> String {
        let formatted = String(format: "%.1f", value)
        return zh ? "plus=\(formatted)" : "plus=\(formatted)"
    }
    static func quotaSortProRatioValue(_ value: Double, absoluteProWeight: Double) -> String {
        let ratio = String(format: "%.1f", value)
        let proWeight = String(format: "%.1f", absoluteProWeight)
        return zh ? "pro=plus×\(ratio) (= \(proWeight))" : "pro=plus×\(ratio) (= \(proWeight))"
    }
    static func quotaSortTeamRatioValue(_ value: Double, absoluteTeamWeight: Double) -> String {
        let ratio = String(format: "%.1f", value)
        let teamWeight = String(format: "%.1f", absoluteTeamWeight)
        return zh ? "team=plus×\(ratio) (= \(teamWeight))" : "team=plus×\(ratio) (= \(teamWeight))"
    }
    static var launchAtLoginTitle: String { zh ? "开机启动" : "Launch at Login" }
    static var launchAtLoginHint: String {
        zh ? "系统启动时自动运行 Codex，便于快速使用" : "Automatically run Codex when the system starts, so it is ready to use."
    }
    static var accountOrderTitle: String { zh ? "OpenAI 账号顺序" : "OpenAI Account Order" }
    static var accountOrderingModeTitle: String { zh ? "账号排序方式" : "Account Ordering" }
    static var accountOrderingModeHint: String {
        zh
            ? "可在“按用量排序”和“按手动顺序”之间切换。只有切到手动顺序时，下面的手动排序才会影响主菜单展示。"
            : "Switch between quota-based sorting and manual order. The manual list below only affects the main menu when manual order is selected."
    }
    static var accountOrderingModeQuotaSort: String { zh ? "按用量排序" : "Sort by Quota" }
    static var accountOrderingModeQuotaSortHint: String {
        zh ? "直接按当前用量权重排序，剩余可用更多的账号优先。" : "Use the current quota-weighted ranking directly, with accounts that have more usable quota first."
    }
    static var accountOrderingModeManual: String { zh ? "按手动顺序" : "Manual Order" }
    static var accountOrderingModeManualHint: String {
        zh ? "按你保存的手动顺序展示；active / running 账号仍会临时浮顶。" : "Use your saved manual order for display; active and running accounts still float to the top temporarily."
    }
    static var accountOrderHint: String {
        zh
            ? "这里定义手动顺序。只有在上方选了“按手动顺序”后它才生效；active / running 账号仍会临时浮顶。"
            : "This defines the manual order. It only takes effect when \"Manual Order\" is selected above, and active/running accounts still float to the top."
    }
    static var accountOrderInactiveHint: String {
        zh ? "当前按用量排序；你仍可预先调整手动顺序，等切到“按手动顺序”后再生效。" : "Quota sorting is currently active. You can still prepare the manual order below, and it will apply once you switch to Manual Order."
    }
    static var noOpenAIAccountsForOrdering: String { zh ? "当前没有可排序的 OpenAI 账号。" : "There are no OpenAI accounts to reorder." }
    static var moveUp: String { zh ? "上移" : "Move Up" }
    static var moveDown: String { zh ? "下移" : "Move Down" }
    static var launchCodexPromptTitle: String { zh ? "操作成功" : "Action succeeded" }
    static var launchCodexPromptMessage: String { zh ? "是否要新开 Codex 实例？" : "Do you want to launch a new Codex instance?" }
    static var launchCodexPromptConfirm: String { zh ? "是，新开 Codex 实例" : "Yes, launch a new Codex instance" }
    static var launchCodexPromptCancel: String { zh ? "否，稍后手动重启 Codex" : "No, restart Codex manually later" }
    static var manualSwitchDefaultTargetUpdatedTitle: String {
        zh ? "默认目标已更新" : "Default target updated"
    }
    static func manualSwitchDefaultTargetUpdatedDetail(_ target: String?) -> String {
        if let target, target.isEmpty == false {
            return zh
                ? "后续新请求默认走 \(target)；当前运行中的 thread 不保证切换。"
                : "New requests now default to \(target); running threads are not guaranteed to switch."
        }
        return zh
            ? "后续新请求会使用新的默认目标；当前运行中的 thread 不保证切换。"
            : "New requests will use the new default target; running threads are not guaranteed to switch."
    }
    static var manualSwitchLaunchedInstanceTitle: String {
        zh ? "默认目标已更新并已新开实例" : "Default target updated and new instance launched"
    }
    static func manualSwitchLaunchedInstanceDetail(_ target: String?) -> String {
        if let target, target.isEmpty == false {
            return zh
                ? "新的 Codex 实例会使用 \(target)；已在运行的实例会继续保留，现有 thread 也不会被接管。"
                : "The new Codex instance will use \(target); existing instances stay open, and running threads keep their current target."
        }
        return zh
            ? "新的 Codex 实例会使用新的默认目标；已在运行的实例会继续保留，现有 thread 也不会被接管。"
            : "The new Codex instance will use the new default target; existing instances stay open, and running threads keep their current target."
    }
    static var manualSwitchImmediateEffectHint: String {
        zh ? "如要立刻生效，请新开实例。" : "Launch a new instance if you need it to take effect immediately."
    }
    static var aggregateRuntimeActiveTitle: String {
        zh ? "聚合运行态仍在影响后续路由" : "Aggregate runtime is still affecting future routing"
    }
    static func aggregateRuntimeActiveDetail(_ routedAccount: String?) -> String {
        if let routedAccount, routedAccount.isEmpty == false {
            return zh
                ? "最近路由摘要仍停留在 \(routedAccount)。同一 thread 可能继续沿用旧 sticky；这只是摘要，不代表全部 live thread。"
                : "The latest route summary still points at \(routedAccount). The same thread may keep following an older sticky binding; this is only a summary, not the truth for every live thread."
        }
        return zh
            ? "聚合 gateway 仍按会话路由 OpenAI 账号。最近路由只作摘要，不代表全部 live thread。"
            : "The aggregate gateway is still routing OpenAI accounts per session. The latest route is only a summary, not the truth for every live thread."
    }
    static var aggregateRuntimeSwitchBackTitle: String {
        zh ? "新流量已回手动模式，旧聚合线程仍在续跑" : "New traffic is back on manual mode while old aggregate threads keep running"
    }
    static func aggregateRuntimeSwitchBackDetail(
        targetAccount: String?,
        routedAccount: String?
    ) -> String {
        if let targetAccount, targetAccount.isEmpty == false,
           let routedAccount, routedAccount.isEmpty == false {
            return zh
                ? "默认目标是 \(targetAccount)，但最近路由摘要仍停留在 \(routedAccount)。这通常是旧 aggregate lease 或 sticky 尚未自然收敛，不代表切号失败。"
                : "The default target is \(targetAccount), but the latest route summary still points at \(routedAccount). That usually means an older aggregate lease or sticky binding has not naturally drained yet, not that switching failed."
        }
        if let targetAccount, targetAccount.isEmpty == false {
            return zh
                ? "默认目标已回到 \(targetAccount)，但旧 aggregate lease 或 sticky 仍可能影响未结束的线程。这不代表切号失败。"
                : "The default target is back on \(targetAccount), but an older aggregate lease or sticky binding may still affect threads that have not finished. That does not mean switching failed."
        }
        return zh
            ? "新流量已回手动模式，但旧 aggregate lease 或 sticky 仍可能影响尚未结束的线程。这不代表切号失败。"
            : "New traffic is back on manual mode, but an older aggregate lease or sticky binding may still affect threads that have not finished. That does not mean switching failed."
    }
    static var aggregateRuntimeClearStaleStickyAction: String {
        zh ? "清理过期 sticky" : "Clear Stale Sticky"
    }
    static var aggregateRuntimeClearStaleStickyHint: String {
        zh
            ? "清理后只影响 future routing / new thread，不接管正在运行的 thread。"
            : "Clearing it only affects future routing / new threads and does not take over running threads."
    }
    static var save: String { zh ? "保存" : "Save" }
    static var codexAppPathSectionTitle: String { zh ? "Codex App 路径" : "Codex App Path" }
    static var codexAppPathTitle: String { zh ? "文件路径" : "Path" }
    static var codexAppPathHint: String {
        zh
            ? "手动路径优先；路径失效时会自动回退系统探测。有效路径必须是绝对路径、指向 Codex.app，并包含 Contents/Resources/codex。"
            : "A manual path takes priority, but invalid paths fall back to automatic detection. Valid paths must be absolute, point to Codex.app, and include Contents/Resources/codex."
    }
    static var codexAppPathChooseAction: String { zh ? "选择" : "Choose" }
    static var codexAppPathResetAction: String { zh ? "恢复自动探测" : "Use Auto Detection" }
    static var codexAppPathPanelTitle: String { zh ? "选择 Codex.app" : "Choose Codex.app" }
    static var codexAppPathPanelMessage: String {
        zh ? "请选择一个有效的 Codex.app。" : "Choose a valid Codex.app."
    }
    static var codexAppPathEmptyValue: String { zh ? "当前未设置手动路径" : "No manual path selected" }
    static var codexAppPathUsingManualStatus: String { zh ? "使用手动路径" : "Using the manual path" }
    static var codexAppPathInvalidFallbackStatus: String { zh ? "手动路径无效，已回退自动探测" : "Manual path is invalid; falling back to automatic detection" }
    static var codexAppPathAutomaticStatus: String { zh ? "当前使用自动探测" : "Currently using automatic detection" }
    static var codexAppPathInvalidSelection: String {
        zh
            ? "所选路径不是有效的 Codex.app。请确认它是绝对路径、名为 Codex.app，并包含 Contents/Resources/codex。"
            : "The selected path is not a valid Codex.app. Make sure it is an absolute path named Codex.app and includes Contents/Resources/codex."
    }
    static var openAICSVExportPrompt: String { zh ? "导出" : "Export" }
    static var openAICSVImportPrompt: String { zh ? "导入" : "Import" }
    static var noOpenAIAccountsToExport: String {
        zh ? "没有可导出的 OpenAI 账号" : "No OpenAI accounts available to export"
    }
    static func openAICSVExportSucceeded(_ count: Int) -> String {
        zh ? "已导出 \(count) 个 OpenAI 账号。" : "Exported \(count) OpenAI account\(count == 1 ? "" : "s")."
    }
    static func openAICSVImportSucceeded(
        added: Int,
        updated: Int,
        activeChanged: Bool,
        providerChanged: Bool,
        preservedCompatibleProvider: Bool
    ) -> String {
        let prefix = zh
            ? "已导入 OpenAI 账号：新增 \(added) 个，覆盖 \(updated) 个。"
            : "Imported OpenAI accounts: \(added) added, \(updated) updated."
        let suffix: String
        if preservedCompatibleProvider {
            suffix = zh ? " 当前使用 provider 保持不变。" : " The current provider was left unchanged."
        } else if providerChanged {
            suffix = zh ? " 当前 provider 已切换到 OpenAI。" : " The current provider was switched to OpenAI."
        } else if activeChanged {
            suffix = zh ? " 当前 OpenAI 账号已更新。" : " The current OpenAI account was updated."
        } else {
            suffix = zh ? " 当前 active 选择未变化。" : " The current active selection was unchanged."
        }
        return prefix + suffix
    }
    static var openAIAccountDataEmptyFile: String { zh ? "账号文件为空。" : "The account file is empty." }
    static var openAIAccountDataInvalidFile: String { zh ? "账号文件格式无效。" : "The account file format is invalid." }
    static var openAIAccountDataUnsupportedType: String { zh ? "不支持的账号文件类型。" : "Unsupported account file type." }
    static var openAIAccountDataNoImportableAccounts: String { zh ? "文件里没有可导入的 OpenAI OAuth 账号。" : "The file does not contain any importable OpenAI OAuth accounts." }
    static func openAIAccountDataMissingRequiredValue(_ index: Int) -> String {
        zh ? "第 \(index) 个 OpenAI 账号缺少必填字段。" : "OpenAI account \(index) is missing required fields."
    }
    static func openAIAccountDataInvalidAccount(_ index: Int) -> String {
        zh ? "第 \(index) 个 OpenAI 账号的 token 校验失败。" : "OpenAI account \(index) failed token validation."
    }
    static var openAIAccountDataMissingColumns: String { zh ? "旧版账号文件缺少必需列。" : "The legacy account file is missing required columns." }
    static var openAIAccountDataUnsupportedVersion: String { zh ? "不支持的旧版账号文件版本。" : "Unsupported legacy account file version." }
    static func openAIAccountDataInvalidRow(_ row: Int) -> String {
        zh ? "旧版账号文件第 \(row) 行格式无效。" : "Legacy account file row \(row) has an invalid format."
    }
    static func openAIAccountDataAccountIDMismatch(_ row: Int) -> String {
        zh ? "旧版账号文件第 \(row) 行的 account_id 校验失败。" : "Legacy account file row \(row) failed account_id validation."
    }
    static func openAIAccountDataEmailMismatch(_ row: Int) -> String {
        zh ? "旧版账号文件第 \(row) 行的 email 校验失败。" : "Legacy account file row \(row) failed email validation."
    }
    static var openAIAccountDataDuplicateAccounts: String { zh ? "账号文件中存在重复的 account_id。" : "The account file contains duplicate account_id values." }
    static var openAIAccountDataMultipleActiveAccounts: String { zh ? "旧版账号文件中包含多个 is_active=true 的账号。" : "The legacy account file contains multiple accounts marked as is_active=true." }
    static func openAIAccountDataInvalidActiveValue(_ row: Int) -> String {
        zh ? "旧版账号文件第 \(row) 行的 is_active 值无效。" : "Legacy account file row \(row) has an invalid is_active value."
    }
    static var quit: String            { zh ? "退出"               : "Quit" }
    static var restart: String         { zh ? "重启"               : "Restart" }
    static var powerMenu: String       { zh ? "重启或退出"          : "Restart or Quit" }
    static var cancel: String          { zh ? "取消"               : "Cancel" }
    static var copied: String          { zh ? "已复制"             : "Copied" }
    static var justUpdated: String     { zh ? "刚刚更新"            : "Just updated" }
    static var authRecoveryDeferredMsg: String {
        zh ? "授权恢复尚未完成，请稍后再试" : "Auth recovery is not finished yet. Please try again shortly."
    }
    static var authValidationFailedMsg: String {
        zh ? "授权校验失败，请稍后重试" : "Authorization check failed. Please try again later."
    }
    static var addProviderTitle: String { zh ? "添加 Provider" : "Add Provider" }
    static var editProviderTitle: String { zh ? "编辑 Provider" : "Edit Provider" }
    static var addProviderAction: String { zh ? "添加" : "Add" }
    static var saveProviderAction: String { zh ? "保存" : "Save" }
    static var providerNameLabel: String { zh ? "Provider 名称" : "Provider Name" }
    static var providerBaseURLLabel: String { zh ? "Base URL" : "Base URL" }
    static var providerAccountLabel: String { zh ? "账号名称" : "Account Label" }
    static var providerAPIKeyLabel: String { zh ? "API Key" : "API Key" }
    static var editBtn: String { zh ? "编辑" : "Edit" }
    static var addProviderAccountTitle: String { zh ? "添加 Provider 账号" : "Add Provider Account" }
    static var editProviderAccountTitle: String { zh ? "编辑 Provider 账号" : "Edit Provider Account" }
    static func editContextMenuItem(_ object: String) -> String {
        zh ? "编辑「\(object)」" : "Edit \"\(object)\""
    }
    static func deleteContextMenuItem(_ object: String) -> String {
        zh ? "删除「\(object)」" : "Delete \"\(object)\""
    }
    static func exportContextMenuItem(_ object: String) -> String {
        zh ? "导出「\(object)」" : "Export \"\(object)\""
    }
    static func providerAccountContextObject(_ provider: String, _ account: String) -> String {
        zh ? "\(provider) / \(account)" : "\(provider) / \(account)"
    }
    static func openRouterKeyContextObject(_ account: String) -> String {
        zh ? "OpenRouter Key：\(account)" : "OpenRouter Key: \(account)"
    }
    static func openAIAccountContextObject(_ account: String) -> String {
        zh ? "OpenAI 账号：\(account)" : "OpenAI Account: \(account)"
    }
    static func providerContextObject(_ provider: String) -> String {
        zh ? "Provider：\(provider)" : "Provider: \(provider)"
    }
    static var addOpenRouterKeyTitle: String { zh ? "添加 OpenRouter Key" : "Add OpenRouter Key" }
    static var editOpenRouterKeyTitle: String { zh ? "编辑 OpenRouter Key" : "Edit OpenRouter Key" }
    static var openRouterKeyLabelOptional: String { zh ? "Key 标签（可选）" : "Key Label (Optional)" }
    static var openRouterKeyLabelPlaceholder: String { zh ? "例如：主力账号、备用 Key" : "Example: Primary, Backup key" }
    static var openRouterManageModelsAction: String { zh ? "管理" : "Manage" }
    static var openRouterNoModelsSelected: String { zh ? "未选择模型" : "No models selected" }
    static func openRouterSelectedModelsSummary(_ count: Int) -> String {
        zh ? "已选 \(count) 个模型" : "\(count) selected model\(count == 1 ? "" : "s")"
    }
    static func openRouterHiddenModelsSummary(_ count: Int) -> String {
        zh ? "另有 \(count) 个模型" : "+ \(count) more model\(count == 1 ? "" : "s")"
    }
    static var openRouterModelPickerRefresh: String { zh ? "刷新模型" : "Refresh Models" }
    static var openRouterModelPickerRefreshing: String { zh ? "刷新中…" : "Refreshing..." }
    static var openRouterModelPickerSearchPlaceholder: String { zh ? "搜索模型" : "Search Models" }
    static var openRouterModelPickerSearchPrompt: String {
        zh ? "输入关键词搜索缓存模型。" : "Type to search cached models."
    }
    static var openRouterModelPickerNoMatches: String { zh ? "没有匹配的模型。" : "No models match the current search." }
    static var openRouterModelPickerNoCache: String { zh ? "还没有缓存模型" : "No cached models yet" }
    static func openRouterModelPickerSelectedCount(_ count: Int) -> String {
        zh ? "已选 \(count) 个" : "\(count) selected"
    }
    static func openRouterModelPickerCacheStatus(count: Int, fetchedAt: Date?) -> String {
        let countText = zh ? "已缓存 \(count) 个模型" : "\(count) cached models"
        guard let fetchedAt else { return countText }
        let formatter = DateFormatter()
        formatter.locale = zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = zh ? "yyyy年M月d日 H:mm" : "MMMM d, yyyy 'at' H:mm"
        let updatedText = zh ? "更新于 \(formatter.string(from: fetchedAt))" : "updated \(formatter.string(from: fetchedAt))"
        return "\(countText) • \(updatedText)"
    }
    static func openRouterModelPickerRefreshSuccess(_ count: Int) -> String {
        zh ? "已刷新 \(count) 个模型。" : "Refreshed \(count) models."
    }
    static var openRouterModelPickerRefreshFailure: String {
        zh ? "刷新失败，已保留当前选择和缓存模型。" : "Refresh failed. Keeping the current selection and cached models."
    }
    static var deleteOpenAIAccountConfirmTitle: String {
        zh ? "删除 OpenAI 账号？" : "Delete OpenAI Account?"
    }
    static var deleteProviderAccountConfirmTitle: String {
        zh ? "删除 Provider 账号？" : "Delete Provider Account?"
    }
    static var deleteProviderConfirmTitle: String {
        zh ? "删除 Provider？" : "Delete Provider?"
    }
    static func deleteOpenAIAccountConfirmMessage(_ account: String) -> String {
        zh
            ? "确认删除「\(account)」？此操作会从 Codexbar 管理列表中移除该账号。"
            : "Delete \"\(account)\" from Codexbar's managed account list?"
    }
    static func deleteProviderAccountConfirmMessage(_ account: String, _ provider: String) -> String {
        zh
            ? "确认从「\(provider)」删除账号「\(account)」？"
            : "Delete account \"\(account)\" from \"\(provider)\"?"
    }
    static func deleteProviderConfirmMessage(_ provider: String) -> String {
        zh
            ? "确认删除「\(provider)」及其账号？"
            : "Delete \"\(provider)\" and its accounts?"
    }

    static func available(_ n: Int, _ total: Int) -> String {
        zh ? "\(n)/\(total) 可用" : "\(n)/\(total) Available"
    }
    static func minutesAgo(_ m: Int) -> String {
        zh ? "\(m) 分钟前更新" : "Updated \(m) min ago"
    }
    static func hoursAgo(_ h: Int) -> String {
        zh ? "\(h) 小时前更新" : "Updated \(h) hr ago"
    }
    // MARK: - AccountRowView
    static var reauth: String          { zh ? "重新授权"     : "Re-authorize" }
    static var useBtn: String          { providerUseAction }
    static var switchBtn: String       { openAIAccountSwitchAction }
    static var tokenExpiredMsg: String { zh ? "Token 已过期，请重新授权" : "Token expired, please re-authorize" }
    static var bannedMsg: String       { zh ? "账号已停用"   : "Account suspended" }
    static var deleteBtn: String       { zh ? "删除"         : "Delete" }
    static var deleteConfirm: String   { zh ? "删除"         : "Delete" }
    static var nextUseTitle: String    { zh ? "下一次使用"   : "Next Use" }
    static var inUseNone: String       { zh ? "未检测到正在使用的 OpenAI 会话" : "No live OpenAI sessions detected" }
    static var runningThreadNone: String { zh ? "未检测到运行中的 OpenAI 线程" : "No running OpenAI threads detected" }
    static var runningThreadUnavailable: String { zh ? "运行中状态不可用" : "Running status unavailable" }
    static var runningThreadUnavailableRuntimeLogMissing: String {
        zh ? "运行中状态不可用（未找到运行日志库）" : "Running status unavailable (runtime log database missing)"
    }
    static var runningThreadUnavailableRuntimeLogUninitialized: String {
        zh ? "运行中状态不可用（运行日志库未初始化）" : "Running status unavailable (runtime logs not initialized)"
    }

    static func inUseSessions(_ count: Int) -> String {
        zh ? "使用中 · \(count) 个会话" : "In Use · \(count) session\(count == 1 ? "" : "s")"
    }

    static func runningThreads(_ count: Int) -> String {
        zh ? "运行 \(count)" : "Running \(count)"
    }

    static func inUseSummary(_ sessions: Int, _ accounts: Int) -> String {
        if zh {
            return "使用中 · \(sessions) 个会话 / \(accounts) 个账号"
        }
        return "In Use · \(sessions) session\(sessions == 1 ? "" : "s") across \(accounts) account\(accounts == 1 ? "" : "s")"
    }

    static func runningThreadSummary(_ threads: Int, _ accounts: Int) -> String {
        if zh {
            return "运行中 · \(threads) 个线程 / \(accounts) 个账号"
        }
        return "Running · \(threads) thread\(threads == 1 ? "" : "s") / \(accounts) account\(accounts == 1 ? "" : "s")"
    }

    static func inUseUnknownSessions(_ count: Int) -> String {
        zh ? "另有 \(count) 个未归因会话" : "\(count) unattributed session\(count == 1 ? "" : "s")"
    }

    static func runningThreadUnknown(_ count: Int) -> String {
        zh ? "另有 \(count) 个未归因线程" : "\(count) unattributed thread\(count == 1 ? "" : "s")"
    }

    static func openAIRouteSummaryCompact(_ value: String) -> String {
        zh ? "约\(value)" : "~\(value)"
    }

    static var delete: String         { zh ? "删除"     : "Delete" }
    static var tokenExpiredHint: String { zh ? "Token 已过期，请重新授权" : "Token expired, please re-authorize" }
    static var accountSuspended: String { zh ? "账号已停用" : "Account suspended" }
    static var weeklyExhausted: String  { zh ? "周额度耗尽" : "Weekly quota exhausted" }
    static var primaryExhausted: String { zh ? "5h 额度耗尽" : "5h quota exhausted" }
    nonisolated static func compactResetDaysHours(_ days: Int, _ hours: Int) -> String {
        zh ? "\(days)天\(hours)时" : "\(days)d \(hours)h"
    }
    nonisolated static func compactResetHoursMinutes(_ hours: Int, _ minutes: Int) -> String {
        zh ? "\(hours)时\(minutes)分" : "\(hours)h \(minutes)m"
    }
    nonisolated static func compactResetMinutes(_ minutes: Int) -> String {
        zh ? "\(minutes)分" : "\(minutes)m"
    }
    nonisolated static var compactResetSoon: String {
        zh ? "1分内" : "<1m"
    }

    // MARK: - TokenAccount status
    static var statusOk: String       { zh ? "正常"     : "OK" }
    static var statusWarning: String  { zh ? "即将用尽" : "Warning" }
    static var statusExceeded: String { zh ? "额度耗尽" : "Exceeded" }
    static var statusBanned: String   { zh ? "已停用"   : "Suspended" }

    // MARK: - Reset countdown
    static var resetSoon: String { zh ? "即将重置" : "Resetting soon" }
    static func resetInMin(_ m: Int) -> String {
        zh ? "\(m) 分钟后重置" : "Resets in \(m) min"
    }
    static func resetInHr(_ h: Int, _ m: Int) -> String {
        zh ? "\(h) 小时 \(m) 分后重置" : "Resets in \(h)h \(m)m"
    }
    static func resetInDay(_ d: Int, _ h: Int) -> String {
        zh ? "\(d) 天 \(h) 小时后重置" : "Resets in \(d)d \(h)h"
    }
}

enum AppVersionDisplay {
    static var versionAndBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let cleanVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVersion = cleanVersion?.isEmpty == false ? cleanVersion! : "0.0.0"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return resolvedVersion
        }
        let cleanBuild = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanBuild.isEmpty == false else { return resolvedVersion }
        return "\(resolvedVersion) (Build \(cleanBuild))"
    }
}
