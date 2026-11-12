# 模型切换交互调整

主面板开关移到标题下方，移除额外重新加载链接。在 Codex 中切换模型时隐藏 Active card；第三方管理区域按实际方式隐藏使用按钮和当前状态。

设置采用 Radio，标题为“切换模型方式”。选择后先暂存，立即显示重启提示；重启或稍后才应用，取消不应用选择。主面板开关同样先确认后应用。常规页直接提供 OpenAI 账号手动顺序，移除排序模式选择；用量页不再提供套餐排序权重。

Provider 卡片支持拖放到其他 Provider 前面，顺序单独持久化，不同步 Codex 配置。主题色从当前模型品牌映射取得，多色及未知标志回退蓝色。

修改文件及作用：
- `MenuBarView.swift`：开关位置、Active card、确认前暂存和取消交互。
- `MenuBarOpenAIModeSections.swift`：移除重新加载链接。
- `SettingsWindowView.swift`：Radio、三选项重启提示、按钮隐藏、移除旧账号排序 UI。
- `SettingsWindowCoordinator.swift`：接受已保存路由并清除草稿脏状态。
- `MenuBarOpenAIAccountSections.swift`：Provider 顺序展示与拖放入口。
- `CodexBarConfig.swift`：兼容读取并保存 Provider 显示顺序。
- `TokenStore.swift`：持久化排序，不改请求目标。
- `ModelTheme.swift`：品牌主题色映射。

验证：修改 Swift 文件通过语法解析，git diff --check 通过。本轮未执行 Xcode 类型检查、运行测试、构建或安装。

手动验收：选择两种 Radio 后分别取消、稍后及重启，检查取消前后配置不变；Codex 中切换时不显示 Active card 或第三方使用按钮；拖动 Provider 后关闭再打开面板，确认顺序保留；检查单色品牌主题、多色蓝色回退及常规页排序选项移除。
