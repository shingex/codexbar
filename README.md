# codexbar

让 Codex Desktop 用同一个 `~/.codex` 管理 OpenAI 多账号、第三方中转站、OpenRouter 与本地用量统计。

`codexbar` 是一个 macOS 菜单栏工具，负责管理 Codex Desktop 背后的账号、provider、网关和本地 session。它适合已经在使用多个 OpenAI OAuth 账号、第三方 OpenAI 兼容中转站、OpenRouter，或者需要同时兼顾桌面端和移动端 Codex 使用的人。

这个仓库是在原始 `codexbar` 基础上继续演进的独立版本。当前重点是：OpenAI OAuth 多账号、聚合网关、OpenRouter / 自定义 provider 路由、Sub2API 账号互通、移动端局域网访问，以及本地 usage / 成本汇总。

[English](./README.en.md)

## 一眼看懂

- 一个 `~/.codex`，同时服务多个 OpenAI OAuth 账号和多个 provider
- OpenAI 账号支持 **手动切换 / 聚合网关 / 混合路由** 三种使用方式
- 使用第三方中转站后，仍可通过本地 OpenAI gateway 保留 Codex 插件、MCP、移动端等依赖 OpenAI 账号态的能力
- OpenRouter 和自定义 OpenAI 兼容 provider 可以挂在同一套菜单里，按模型和 API key 管理
- gateway 监听局域网地址，移动端可用 Mac 的局域网 IP 加端口访问同一套路由
- OpenAI 账号 CSV 导入 / 导出兼容 Sub2API，方便批量整理和迁移
- 本地扫描 `sessions` / `archived_sessions`，直接显示 token、usage 和成本估算

## 主要场景

### 多账号不拆历史

很多切号方案会给每个账号单独建一套 `CODEX_HOME`。隔离很彻底，但历史、resume、归档 session 也会被拆开。

`codexbar` 默认保留一个 `~/.codex`，只同步当前要使用的账号、provider 和路由目标。旧 session 仍在同一个历史池里，切换只影响之后发起的新请求。

### 第三方中转站仍保留插件和移动端能力

只把 `openai_base_url` 直接改成第三方中转站，经常会遇到两个麻烦：

- Codex 的部分插件、MCP 或依赖 OpenAI 账号态的能力不再按预期工作
- 移动端要接入同一套 provider 时，需要额外处理本机地址、账号态和配置同步

`codexbar` 的混合路由会保留 OpenAI OAuth 账号作为登录态，同时把请求目标转到 OpenRouter 或自定义 OpenAI 兼容 provider。桌面端继续写入 `127.0.0.1` 的本地 gateway；移动端可以访问 Mac 局域网 IP 上的同一 gateway。

### OpenAI 多账号自动轮转

聚合网关把多个可用的 OpenAI OAuth 账号作为本地账号池。你可以保留一个 Codex 配置入口，让 gateway 根据当前账号状态路由请求，减少手动切号和重复恢复现场。

## 界面截图

下面是当前版本的主要界面。

### OpenAI 账号视图

主菜单展示当前模式、模型、当日与 30 天成本、账号可用量，以及 5 小时 / 7 天窗口的恢复时间。

<p align="center">
  <img src="./docs/assets/readme-openai-accounts-view.png" alt="codexbar OpenAI accounts view" width="652" />
</p>

### Provider 管理视图

Provider 列表可维护 OpenAI 兼容后端、OpenRouter 账号、模型选择、多组 API key、默认目标和当前激活状态。

<p align="center">
  <img src="./docs/assets/readme-provider-management-view.png" alt="codexbar providers view" width="652" />
</p>

### 设置页

设置页集中管理账户模式、排序方式、手动激活行为、Codex Desktop 路径和更新入口。

<p align="center">
  <img src="./docs/assets/readme-settings-window.png" alt="codexbar settings window" width="1120" />
</p>

## 共享 `~/.codex`

- 仍然只保留一个 `~/.codex`
- 保留 `~/.codex/sessions` 和 `~/.codex/archived_sessions` 这一套共享历史池
- 当前激活的 provider / account 会同步到 `~/.codex/config.toml` 和 `~/.codex/auth.json`
- 切换只影响之后发起的新请求和新会话

## 现在支持什么

- 多 OpenAI OAuth 账号管理
- 多 OpenAI 兼容 provider 管理
- OpenRouter 内置 provider / gateway 目标
- 同一 provider 下挂多组 API key
- 菜单栏里快速切换 provider / account
- OpenAI 账号的 **手动切换 / 聚合网关 / 混合路由** 模式
- 第三方中转站场景下保留 OpenAI OAuth 登录态，用于维持插件、MCP 和移动端可用性
- OpenAI gateway `0.0.0.0:1456`，OpenRouter gateway `0.0.0.0:1457`
- OpenAI 账号 CSV 导入 / 导出
- OpenAI 账号支持按用量排序 / 按手动顺序排序
- 设置页里配置手动激活策略与 Codex.app 路径
- 本地 usage / 成本统计
- GitHub Releases 运行时版本检测与手动“检查更新”

本地 usage / 成本统计来自对下面目录的扫描：

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

token 统计只认本地 session，口径固定为：

- `input + cached_input + output`

不会额外拉取或聚合任何远端 usage。金额是基于模型价格表的估算，不等同于官方账单。

## OpenAI 使用模式

### 手动切换

直接把选中的 OpenAI OAuth 账号写入 Codex 配置，适合只想明确指定当前账号的场景。

### 聚合网关

把可用 OpenAI OAuth 账号作为账号池，由本地 gateway 统一承接请求。适合多个账号都有额度、希望减少手动切换的场景。

### 混合路由

保留 OpenAI OAuth 账号作为登录态，把实际请求路由到 OpenRouter 或自定义 OpenAI 兼容 provider。适合已经使用第三方中转站，但仍希望保留 Codex 插件、MCP、移动端访问和账号态能力的场景。

桌面端配置会使用 `127.0.0.1:1456` / `127.0.0.1:1457`；移动端可使用 Mac 的局域网 IP 加对应端口访问。

## 版本检测与更新

客户端运行时会扫描 GitHub Releases，选择**第一个可安装的正式稳定版本**。应用启动时会做非阻塞检查，菜单栏里也可以手动触发“检查更新”。

- 当前稳定版本默认仍是 **guided download / install**
- 发现新版本后，菜单里会显示可用版本和匹配安装包下载入口
- 运行时会跳过 `draft`、`prerelease`、以及不带 `dmg/zip` 资产的 release
- 当前版本不做自动替换旧 app 和自动重启
- `release-feed/stable.json` 只保留这一次 `1.1.8 -> 1.1.9` 的兼容桥接，不再是修复后客户端的运行时真相源
- 如果你已经安装了**首发 1.1.9**，同版本重发不会自动把它识别为可升级；需要手工下载重发 build

更新 bridge / rollout 约定见：

- [docs/update-feed-rollout.md](./docs/update-feed-rollout.md)

## 适合哪些用户

- 同时使用 OpenAI 官方账号和第三方 OpenAI 兼容 provider
- 需要在第三方中转站、OpenRouter、OpenAI OAuth 之间切换，但不想牺牲插件、MCP 或移动端体验
- 同一个 provider 下维护多组 API key 或多个模型入口
- 希望保留同一个 `~/.codex` 历史池，而不是为每个账号维护一套独立目录

## Star 历史

<p align="center">
  <a href="https://star-history.com/#shingex/codexbar&Date">
    <picture>
      <source
        media="(prefers-color-scheme: dark)"
        srcset="https://api.star-history.com/svg?repos=shingex/codexbar&type=Date&theme=dark"
      />
      <source
        media="(prefers-color-scheme: light)"
        srcset="https://api.star-history.com/svg?repos=shingex/codexbar&type=Date"
      />
      <img
        alt="codexbar Star History Chart"
        src="https://api.star-history.com/svg?repos=shingex/codexbar&type=Date"
      />
    </picture>
  </a>
</p>

## OpenAI 登录方式

当前 OpenAI 登录采用“浏览器授权 + localhost 回调捕获，必要时可手工粘贴回调”的方式。入口在菜单底部工具栏的人像加号按钮：

1. 点击登录按钮
2. 在浏览器里完成授权
3. 当浏览器跳到 `http://localhost:1455/auth/callback?...` 时，codexbar 会自动捕获回调
4. codexbar 直接完成 token 交换并导入账号

如果自动捕获失败，仍然可以把完整回调 URL 或单独的 `code` 手工粘贴回窗口。

## 成本与账单说明

- 这里展示的是**本地 usage estimate**，不是官方账单页面的精确账单
- 设置页会自动列出本地 session 中出现过的历史模型，你可以直接为这些模型设置 input / cached input / output 单价
- 未配置价格的模型默认按 `0` 成本处理，但 token 汇总仍会正常显示
- 对自定义 OpenAI 兼容 provider，显示的金额不一定等于真实供应商扣费

## 项目边界

`codexbar` 不内置任何私有 provider、私有 API key、私有账号配置。你需要在自己的环境里自行添加这些内容。

## 运行环境

- macOS 13+
- [Codex Desktop / CLI](https://github.com/openai/codex)
- Xcode 15+（如果你要本地编译）

## 本地构建

```sh
git clone https://github.com/shingex/codexbar.git
cd codexbar
open codexbar.xcodeproj
```

然后：

1. 在 Xcode 里选择自己的签名团队
2. 构建并运行 `codexbar` target

## 致谢

这个项目基于原始 `codexbar` 的方向继续改写，并参考、改造了下面 MIT 许可证项目中的思路与部分实现。把原仓列在这里，是为了清楚保留来源关系和感谢原作者的工作：

- [lizhelang/codexbar](https://github.com/lizhelang/codexbar)
- [xmasdong/codexbar](https://github.com/xmasdong/codexbar)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)

详细说明见：

- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## License

[MIT](LICENSE)
