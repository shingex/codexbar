# 更新日志

## 2.0.0 / Build 347

- **模型切换**：新增按会话选择导出模型的方式，同时保留菜单栏选定目标、Codex 跟随固定入口的方式。官方模型继续使用 OAuth；旧混合配置保留目标，聚合账号模式移除。
- **模型与账号管理**：菜单栏重做账号、Provider 和模型卡片，支持拖动调整 Provider 顺序；OpenRouter、OpenCode 和兼容 Provider 的模型选择按 Key 独立保存。
- **请求兼容**：改善跨上游切换时的工具调用历史关联；官方模型保留入站凭据和请求，指定容量错误在同一目标内有限重试，不重放已输出内容。
- **用量**：打开面板时按需刷新上游额度；合并重复请求，遵守服务端退避提示，并支持设置后台轮询间隔。移除本地 token 和成本估算，会话记录仍可浏览和继续。
- **本机控制**：新增 `codexbarctl`，通过本地应用查询状态和管理路由，不直接改写 Codex 配置。

## 1.9.9 / Build 265

- 新增 OpenCode Provider 接入，支持 API Key、模型目录、套餐识别、用量窗口和成本统计。
- 完善 OpenCode 模型选择、每周 / 每月用量展示及重置时间提示。
- 补齐第三方 Provider Gateway 的 `/models` 路由与模型目录缓存，修复 Codex 重启后的模型刷新。
- 修正第三方 Provider 的模型同步、`exec` / `apply_patch` 工具调用映射和新版 Codex CLI 路径识别。
- 在 Gateway 兼容模式下禁用 zstd 请求压缩，并为 Provider WebSocket 提供 HTTP 回退。
- 增强 remote compaction v2 的中断点、工具记录和续接指令保留能力。
- 改进菜单栏账号、模型、用量和操作按钮的字体、悬停提示与 VoiceOver 可访问性标签。
