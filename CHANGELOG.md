# 更新日志

## 1.9.9 / Build 265

- 新增 OpenCode Provider 接入，支持 API Key、模型目录、套餐识别、用量窗口和成本统计。
- 完善 OpenCode 模型选择、每周 / 每月用量展示及重置时间提示。
- 补齐第三方 Provider Gateway 的 `/models` 路由与模型目录缓存，修复 Codex 重启后的模型刷新。
- 修正第三方 Provider 的模型同步、`exec` / `apply_patch` 工具调用映射和新版 Codex CLI 路径识别。
- 在 Gateway 兼容模式下禁用 zstd 请求压缩，并为 Provider WebSocket 提供 HTTP 回退。
- 增强 remote compaction v2 的中断点、工具记录和续接指令保留能力。
- 改进菜单栏账号、模型、用量和操作按钮的字体、悬停提示与 VoiceOver 可访问性标签。
