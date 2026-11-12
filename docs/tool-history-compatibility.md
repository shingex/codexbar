# 跨上游工具历史兼容

本轮修改：
- `codexBar/Services/ToolHistoryCompatibility.swift`：按整个 input 顺序建立工具条目 ID／call_id 映射，检查非空值，成对修复结果引用；缺失引用仅在存在唯一同类型待完成调用时补齐，否则抛出明确错误。按调用类型规范工具条目 ID，保留 call_id 关联；合法请求返回原始字节。
- `codexBar/Services/OpenAIAccountGatewayService.swift`：在官方请求与选定第三方适配边界调用修复器；关联不明确返回 400；新生成的 custom_tool_call 使用 ctc_ ID，空第三方 ID 使用非空检查；流式条目等待工具名后生成类型对应 ID。
- `codexBarTests/ToolHistoryCompatibilityTests.swift`：空值配对、条目引用转换、歧义拒绝及官方合法正文不变回归。
- `AGENTS.md`：记录官方透明正文的工具历史兼容例外。
- `codexbar.xcodeproj/project.pbxproj`：Build 331。

选择统一修复器，是为了避免调用与结果分别补 ID 导致关联丢失。仅在转发副本上处理工具字段，不修改用户 JSONL 历史、工具参数或工具结果内容。

验证：84 项针对性 XCTest 全部通过，涵盖新修复器和 OpenAIAccountGatewayServiceTests。日志 `/tmp/codexbar-history-tests.log`。未获取原失败会话的实际请求，因此尚未确认具体是哪一条历史记录触发错误。

手动验证：自行重启 CodexBar 加载新版，在原会话中从 OAuth 切到第三方模型，完成一次工具调用，再切回 OAuth 并继续。检查不再出现空 call_id 或 ct_/ctc 前缀错误，并验证工具结果仍关联正确调用。若返回关联歧义错误，需要进一步核对脱敏后的调用／结果结构，不能随意将结果绑定到任意工具。

## Build 332：持续使用外部模型时的补充修复

- `ToolHistoryCompatibility.swift` 改为逐项处理异构 input，不再因某一条字符串或其他非字典内容跳过整段历史；兼容 response.create.response 包装，并保留未修改请求的原始字节。
- `OpenAIAccountGatewayService.swift` 在兼容 Provider、OpenRouter 的底层公共发送边界统一修复，因此固定模型入口、旧路由及测试路径均覆盖。
- `ToolHistoryCompatibilityTests.swift` 增加 input[553] 空 call_id、混合历史、嵌套包装的回归。
- Build 332；86 项针对性测试通过，日志 `/tmp/codexbar-history-tests.log`。

实际失败请求尚未采集，以上是源码确认的绕过路径，不代表已定位用户会话的具体第 553 条记录。当前进程 PID 28513 的启动时间为 20:49:52，早于 Build 331 安装；需自行重启 CodexBar 才会载入新代码。

## Build 333：新版 Codex 上下文记录导致误判歧义

- 按新版 Codex（如 2026-11 的会话记录）复现：`function_call_output` 会携带 `id`、`name`、`namespace` 与 `output`，但没有 `call_id`，也不存在对应的 `function_call`。这类条目是 `codex_apps_open_page` 等上下文记录，不是工具调用结果。旧逻辑会把它当作结果去匹配待完成调用，匹配不到即抛出歧义错误；而恢复原生 OAuth 会话时历史必然回放这些条目，于是直接 400。
- `ToolHistoryCompatibility.swift`：没有 `call_id` 且带 `name`／`namespace` 的输出条目直接保留，不参与关联，也不消耗待完成调用；真正的空 `call_id` 结果仍按原规则唯一配对，无法唯一关联时继续明确报错。
- `OpenAIAccountGatewayService.swift`：第三方 Chat Completions 转换遇到同类上下文记录时改写成 `system` 上下文消息，不再生成不存在的 `tool_call_id`。
- `OpenAIAccountGatewayServiceTests.swift` 与 `ToolHistoryCompatibilityTests.swift` 增加原生上下文记录、待完成调用不被抢占、第三方转换回归。
- Build 333；81 项 `OpenAIAccountGatewayServiceTests` 与 8 项 `ToolHistoryCompatibilityTests` 通过，日志 `/tmp/codexbar-history-tests-333.log`、`/tmp/codexbar-gateway-tests-333.log`。
- 用本机 2026-11-10 的 1156 条原生会话记录（含 8 条上下文记录）重放修复器：不再抛出歧义错误，且返回原始字节。


## Build 335：原生 Responses 上下文记录兼容

Build 333 的具名上下文记录被原样保留，因此只避免了本地关联歧义，仍会把空 call_id 的 function_call_output 发往官方或原生 Responses 接口。本轮修复这个遗漏。

修改文件及作用：
- `ToolHistoryCompatibility.swift`：将不存在对应调用的具名上下文输出转换为普通 user/input_text 消息；保留其内容，不伪造调用，也不提升为系统指令。有待完成调用时延后上下文消息，直到该组工具结果结束。具名真实结果仍按唯一匹配的工具名关联。
- `ToolHistoryCompatibilityTests.swift`：更新上下文转换、幂等性、待完成调用不被上下文抢占的预期。
- `OpenAIAccountGatewayServiceTests.swift`：更新 Chat Completions 的消息顺序回归，新增官方和外部 Responses 实际 HTTP 发送检查，验证上下文保留且真实调用／结果关联有效。
- `AGENTS.md`：补充上下文输出转换的窄范围例外。
- `project.pbxproj`：Build 335。

90 项针对性测试全部通过，日志 `/tmp/codexbar-context-history-tests.log`。没有修改其他 agent 的模型主题、UI 或目录改动；没有修改用户历史 JSONL。

手动验证：自行重启 CodexBar 加载 Build 335，在原会话中选择外部模型继续工具调用，再切回 OAuth，再切回外部模型。确认不再出现空 call_id 或本地关联歧义；上下文信息和工具结果都仍可被后续对话使用。真实失败会话的具体条目尚未直接重放，本轮使用同结构的 HTTP 回归验证。
