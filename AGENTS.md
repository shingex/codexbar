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

# Codexbar Repository Guidance

This repository ships a single operator surface:

- the macOS menu bar app

For OpenAI OAuth account import, use the menu bar app and its localhost callback listener.

## Safety rules

- Do not manually edit `~/.codex/auth.json` or `~/.codex/config.toml` when Codexbar can perform the operation.
- Do not print `access_token`, `refresh_token`, or `id_token` in logs, output, or summaries.
- If low-level repair is explicitly required, mention that the normal path is the Codexbar app before editing auth/config files directly.

## OpenAI 账号关键链路

- 当前实现里，`MenuBarView` 和 `SettingsWindowView` 负责暴露 OpenAI 的使用模式与目标选择；模式切换再交给 `OpenAIAccountUsageModeTransitionExecutor`、`TokenStore` 和各个 gateway 服务落地。
- `TokenStore` 是这条链路的状态中枢，负责 active provider/account、`effectiveGatewayMode`、`routeTarget`、以及 OpenAI gateway / OpenRouter gateway 的生命周期。
- `CodexSyncService` 是唯一负责把当前配置同步到 Codex `auth.json` / `config.toml` 的层；`switch` / `aggregate` / `hybrid` 的写入结果必须和当前 active provider 与账号使用模式一致。
- 配置写入改动必须最小化：不要把 `model_provider`、`openai_base_url`、`model_providers` provider block、gateway 路由、WebSocket / HTTP-only 行为和旧配置清理混在同一次改动里。`[model_providers.*]` 本身可以使用，但只能在明确需要时做窄范围增量；不得为了修一个问题大面积重写用户已有 `config.toml` 结构。
- 修改 `CodexSyncService` 或任何会写 `~/.codex/config.toml` / `~/.codex/auth.json` 的逻辑前，必须先用真实旧配置样本或等价 fixture 做回归；除非用户明确要求迁移，不要删除、重排或覆盖与本次问题无关的既有配置键。
- `hybridProvider` 的语义是保留 OpenAI OAuth 登录态，同时把请求目标切到 custom provider 或 OpenRouter；`aggregateGateway` 只覆盖 OpenAI OAuth 账号池，不把 provider / OpenRouter 混入聚合。
- 当前 gateway 监听在所有 IPv4 地址上，OpenAI gateway 走 `0.0.0.0:1456`，OpenRouter gateway 走 `0.0.0.0:1457`；Codex 本机同步配置仍写 `127.0.0.1:1456` / `127.0.0.1:1457` 作为桌面端稳定访问地址。手机端需要使用 Mac 的局域网 IP 加对应端口访问；如果后续端口或路由边界变化，要同步更新这里和相关测试。
- 任何改动这条链路的提交，都要一起检查 `codexBar/Services/TokenStore.swift`、`codexBar/Services/CodexSyncService.swift`、`codexBar/Services/OpenAIAccountGatewayService.swift`、`codexBar/Services/OpenRouterGatewayService.swift`、`codexBar/Views/MenuBarView.swift`、`codexBar/Views/Settings/SettingsWindowView.swift` 以及对应测试是否仍然同构。

## 本机构建交付

- 只要本次任务需要产出本机可用的 `codexbar.app` 构建，在构建和必要测试通过后，必须把产物安装到本机供用户实际使用，默认目标为 `/Applications/codexbar.app`。
- 本机构建默认只构建当前机器可运行的架构版本，以提高构建效率；例如 Apple Silicon 本机使用 `ONLY_ACTIVE_ARCH=YES` 和 `ARCHS=arm64`。
- 每一次用于交付、安装、发布或让用户实际验证的构建，都必须递增 Xcode 的 `CURRENT_PROJECT_VERSION` Build 号，并在交付说明里同时报告版本号和 Build 号；不得只靠文件时间戳确认构建身份。
- 安装本机构建时不要主动退出、杀掉或重新打开正在运行的 `codexbar` 进程；直接覆盖目标安装副本即可，由用户手动重新打开新版本。
- 如果本机没有可用的开发者签名证书，可为本机实际使用采用 ad-hoc 签名；交付说明里要如实说明签名方式与验证结果。

## 本地安装清理

- 日常测试、构建验证或中间迭代时，不要每次都做完整安装清理，避免重复清理拖慢反馈。
- 当任务进入提交版本、最终交付或发布 `codexbar.app` 时，结束前必须做安装清理，不要留下会在 App Library、Spotlight 或 Launch Services 中表现为“多个 Codexbar”的残留。
- 当任务进入提交版本、最终交付或发布 `codexbar.app` 时，清理本次任务产生或显然属于构建/安装残留的 `codexbar.app` 副本与目录，例如仓库内 build/staging 目录、`DerivedData` 产物、`/private/tmp` 下的临时安装目录、临时挂载出的测试副本。
- 当任务进入提交版本、最终交付或发布 `codexbar.app` 时，必须核对最终可见性：`mdfind`、`lsregister` 或等价检查应只剩目标安装副本，通常是 `/Applications/codexbar.app`。
- 如果系统仍显示重复入口，代理必须继续清理 Launch Services / Spotlight 残留，直到重复入口消失或确认只剩用户明确保留的副本；清理过程不得主动退出、杀掉或重启正在运行的 `codexbar`。
- 不要擅自删除用户主动保存的归档、DMG、备份或仓库外长期保存副本；只有对临时构建产物和明确残留才默认清理。遇到非临时、非生成目录中的额外副本时，先说明再处理。
