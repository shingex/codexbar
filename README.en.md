# codexbar

Use one shared `~/.codex` for OpenAI accounts, third-party relays, OpenRouter, and local usage tracking in Codex Desktop.

`codexbar` is a macOS menu bar utility for managing the accounts, providers, gateways, and local session data behind Codex Desktop. It is built for users who run multiple OpenAI OAuth accounts, third-party OpenAI-compatible relays, OpenRouter, or both desktop and mobile Codex clients.

This repository is an independently maintained continuation of the original `codexbar`. The current focus is OpenAI OAuth multi-account management, aggregate gateway routing, OpenRouter / custom provider routing, Sub2API account interoperability, mobile LAN access, and local usage / cost summaries.

Current version: `1.3.1` (Build `15`).

## At A Glance

- One shared `~/.codex` for multiple OpenAI OAuth accounts and multiple providers
- OpenAI accounts support **manual switch / aggregate gateway / hybrid routing** modes
- Third-party relays can keep Codex plugins, MCP, mobile clients, and other OpenAI-account-dependent features working through a local OpenAI gateway
- OpenRouter and custom OpenAI-compatible providers live in the same menu, with model and API-key management
- Gateways listen on LAN-capable addresses, so mobile clients can use the Mac LAN IP plus port
- OpenAI account CSV import / export is compatible with Sub2API account data
- Local `sessions` / `archived_sessions` are scanned for token, usage, and cost estimates

## Main Use Cases

### Multi-account use without splitting history

Many account-switching setups create a separate `CODEX_HOME` per account. That isolates state, but it also splits history, resume data, and archived sessions.

`codexbar` keeps one `~/.codex` by default and only synchronizes the active account, provider, and route target. Existing sessions remain in the same history pool; switching affects future requests.

### Third-party relays while keeping plugins and mobile clients

Pointing `openai_base_url` directly at a third-party relay often creates two practical problems:

- Codex plugins, MCP, or features that depend on OpenAI account state may stop behaving as expected
- mobile clients need extra work to reach the same provider, account state, and routing configuration

Hybrid routing keeps an OpenAI OAuth account as the login identity while sending requests to OpenRouter or a custom OpenAI-compatible provider. Desktop Codex uses the local `127.0.0.1` gateway; mobile clients can use the same gateway through the Mac LAN IP.

### OpenAI account pooling

The aggregate gateway treats usable OpenAI OAuth accounts as a local account pool. You keep one Codex configuration entry while the gateway routes requests according to current account state.

## Screenshots

These are the main app surfaces.

### OpenAI Account View

The main menu shows the current mode, model, daily and 30-day cost summaries, account availability, and quota-window reset timing.

<p align="center">
  <img src="./docs/assets/readme-openai-accounts-view.png" alt="codexbar OpenAI accounts view" width="652" />
</p>

### Provider Management View

The provider section manages OpenAI-compatible backends, OpenRouter accounts, model selection, multiple API keys, default targets, and active state.

<p align="center">
  <img src="./docs/assets/readme-provider-management-view.png" alt="codexbar providers view" width="652" />
</p>

### Settings Window

The settings window manages account mode, ordering rules, manual activation behavior, preferred Codex Desktop path, and update controls.

<p align="center">
  <img src="./docs/assets/readme-settings-window.png" alt="codexbar settings window" width="1120" />
</p>

## Shared `~/.codex`

- keep a single `~/.codex`
- preserve `~/.codex/sessions` and `~/.codex/archived_sessions` as one shared history pool
- write the active provider / account into `~/.codex/config.toml` and `~/.codex/auth.json`
- let switching affect only future requests and future sessions

## Features

- Multiple OpenAI OAuth accounts
- Multiple OpenAI-compatible providers
- OpenRouter as a built-in provider / gateway target
- Multiple API-key accounts under the same provider
- Fast switching from the menu bar
- OpenAI account modes: **manual switch / aggregate gateway / hybrid routing**
- Preserve OpenAI OAuth login state for plugins, MCP, and mobile-client access when using third-party relays
- OpenAI gateway on `0.0.0.0:1456`; OpenRouter gateway on `0.0.0.0:1457`
- OpenAI account CSV import / export
- OpenAI account ordering: quota-weighted or manual order
- Settings for manual activation behavior and preferred Codex.app path
- Local usage and cost estimates
- Runtime version detection from GitHub Releases plus a manual "Check for Updates" entry

Local usage and cost estimates are derived from:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

Token accounting is local-session only:

- `input + cached_input + output`

No remote usage is fetched or aggregated. Cost values are estimates based on local model pricing tables, not official invoices.

## OpenAI Usage Modes

### Manual switch

Writes the selected OpenAI OAuth account into Codex config. Use this when you want the current account to be explicit.

### Aggregate gateway

Treats usable OpenAI OAuth accounts as a local pool and lets the gateway handle request routing. Use this when several accounts have quota and you want less manual switching.

### Hybrid routing

Keeps an OpenAI OAuth account as the login identity while routing actual requests to OpenRouter or a custom OpenAI-compatible provider. Use this when you already rely on a third-party relay but still want Codex plugins, MCP, mobile access, and account-state-dependent behavior to keep working.

Desktop config uses `127.0.0.1:1456` / `127.0.0.1:1457`; mobile clients can use the Mac LAN IP plus the same port.

## Version Checks and Updates

The client scans GitHub Releases at runtime and chooses the **first installable stable release**. The app also performs a non-blocking check on launch, and the menu bar UI exposes a manual "Check for Updates" action.

- the stable feed is still in **guided download / install** mode
- when a newer version exists, the menu shows the matching installer asset
- runtime checks skip `draft`, `prerelease`, and any release that does not ship installable `dmg` or `zip` assets
- the current build does not replace the old app or restart itself automatically
- `release-feed/stable.json` is now only a one-time compatibility bridge for `1.1.8 -> 1.1.9`; it is no longer the runtime source of truth for fixed clients
- if you already installed the **first 1.1.9 build**, a same-version reissue will not appear as an upgrade automatically; you must download the reissued build manually

See also:

- [docs/update-feed-rollout.md](./docs/update-feed-rollout.md)

## Who This Is For

- You use both official OpenAI accounts and third-party OpenAI-compatible providers
- You switch between third-party relays, OpenRouter, and OpenAI OAuth while keeping plugins, MCP, or mobile clients usable
- You keep multiple API keys or model targets under the same provider
- You want one shared `~/.codex` history pool instead of one directory per account

## Star History

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

## OpenAI Login Flow

OpenAI login currently uses a browser-based authorization flow with localhost callback capture plus a manual fallback. The entry point is the person-plus button in the bottom toolbar:

1. Click the login button
2. Finish authorization in the browser
3. When the browser reaches `http://localhost:1455/auth/callback?...`, codexbar captures the callback automatically
4. codexbar completes token exchange and imports the account

If automatic capture fails, you can still paste the full callback URL or the raw `code` back into the window manually.

## Cost Notes

- Displayed values are **local usage estimates**, not official billing numbers
- for custom OpenAI-compatible providers, displayed cost may differ from actual upstream billing
- unpriced models default to `0` cost while token totals remain visible
- Settings can list models found in local sessions so you can set input / cached input / output prices directly

## Project Scope

This repository does not bundle any private provider, API key, or personal account configuration. You add your own configuration locally.

## Requirements

- macOS 13+
- [Codex Desktop / CLI](https://github.com/openai/codex)
- Xcode 15+ if you want to build locally

## Build Locally

```sh
git clone https://github.com/shingex/codexbar.git
cd codexbar
open codexbar.xcodeproj
```

Then:

1. Select your signing team in Xcode
2. Build and run the `codexbar` target

## Acknowledgements

This project continues from the original `codexbar` direction and references or adapts ideas and parts of the implementation from these MIT-licensed projects. Listing the original repository here keeps the source relationship explicit and gives credit to the original work:

- [lizhelang/codexbar](https://github.com/lizhelang/codexbar)
- [xmasdong/codexbar](https://github.com/xmasdong/codexbar)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)

See also:

- [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)

## License

[MIT](./LICENSE)
