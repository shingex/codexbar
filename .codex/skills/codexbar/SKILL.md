---
name: codexbar
description: Use CodexBar to inspect or change its local provider, account, model, or OpenAI usage mode through codexbarctl.
---

# CodexBar 控制

source: https://github.com/shingex/codexbar

CodexBar 必须正在运行。通过 `codexbarctl` 操作，不要直接编辑 Codex 的认证或配置文件。先运行 `codexbarctl status` 获取 Provider、账号和模型 ID，再按用户意图执行；成功及失败均返回 JSON。`codexbarctl --help` 和子命令 `--help` 提供完整参数。

- `codexbarctl routing on|off`：开启接入或关闭并回到 OAuth 纯净直连；开启恢复上次目标。
- `codexbarctl mode switch|hybrid_provider`：兼容旧脚本的别名，分别等同于 `routing off|on`。
- `codexbarctl activate --provider-id ID --account-id ID [--model-id ID]`：激活目标；选择第三方目标会自动开启接入。
- `codexbarctl model --provider-id ID --account-id ID --model-id ID`：选择账号已勾选的模型。
- `codexbarctl provider-add --label NAME --base-url URL --model-id MODEL --api-key-stdin`：从标准输入读取 Key，添加兼容 Provider。
- `codexbarctl provider-edit --provider-id ID [--label NAME] [--base-url URL] [--account-id ID] [--account-label NAME] [--model-id MODEL] [--model-ids MODEL ...] [--api-key-stdin]`：只修改给出的字段。

不要把密钥写入命令参数、终端历史、输出或日志。若未安装 CLI，参照仓库 README 中的安装说明。

所有 API Key 按 Provider / Key / Model 保存。新增或编辑 Key 必须指定当前请求模型；旧缺模型 Key 不在读取时强制修复，Provider 公共信息编辑不触碰 Key 模型。启用 Codex 接入后，固定 `codexbar` 入口跟随混合路由当前目标；切换 Key / Model 不需要再次重启 Codex。

容量错误重试覆盖官方和 CodexBar 入口：只有指定的容量拒绝会自动重试，单次入站最多 5 次上游请求；已开始业务输出不重放。
