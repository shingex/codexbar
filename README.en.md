# codexbar

A macOS menu bar utility that makes Codex Desktop easier to run with multiple OpenAI accounts, OpenRouter, third-party OpenAI-compatible relays, local gateways, remote access, and local usage tracking.

`codexbar` is built for Codex Desktop / Codex CLI users who manage multiple OpenAI OAuth accounts, multiple API keys, OpenRouter models, third-party relays, or a shared Codex route across Mac and mobile clients.

Current version: `1.7.2` (Build `59`).

[中文](./README.md)

## Download

Download the latest build from GitHub Releases:

- [Download codexbar](https://github.com/shingex/codexbar/releases)
- Requires macOS 13+
- Requires [Codex Desktop / CLI](https://github.com/openai/codex)

`codexbar` does not bundle any private provider, API key, or personal account configuration. Accounts, keys, and providers stay in your local environment.

## Core Capabilities

- **One `~/.codex` for multiple accounts**: keep session history, resume data, and archived sessions in one shared history pool instead of splitting one `CODEX_HOME` per account.
- **OpenAI multi-account aggregate gateway**: treat multiple OpenAI OAuth accounts as a local pool and reduce manual switching.
- **Keep plugins when using relays**: hybrid routing keeps an OpenAI OAuth login identity while sending requests to OpenRouter or a custom OpenAI-compatible provider, helping preserve Codex plugins, MCP, remote access, and account-state-dependent features.
- **Better OpenRouter management**: each OpenRouter key can keep its own selected model and pinned model list, useful for multiple keys, models, and provider routes.
- **LAN remote control / mobile access**: local gateways listen on LAN-capable addresses, so phones or other devices can use the Mac LAN IP and the same route.
- **Local usage and cost estimates**: scan `~/.codex/sessions` and `~/.codex/archived_sessions` for token, usage, and model-cost summaries.
- **Sub2API interoperability**: import and export OpenAI accounts through CSV for batch account cleanup and migration.

## Why codexbar

Codex account and provider configuration ultimately lands in `~/.codex/config.toml` and `~/.codex/auth.json`. Manual switching between accounts, relays, and OpenRouter can quickly become fragile:

- multi-account workflows split session history across directories
- directly changing `openai_base_url` can break plugins, MCP, or features that expect OpenAI login state
- OpenRouter keys and models grow hard to manage in the main config
- desktop, mobile, and remote clients cannot easily share one route
- local token usage and cost estimates lack a single view

`codexbar` keeps one shared `~/.codex`, lets the menu bar manage accounts, providers, models, and gateways, then synchronizes the minimum required Codex configuration for the current mode.

## Screenshots

### Menu Bar Panel

The main panel shows the current mode, OAuth account, model, local usage estimate, and quick switching entries for Provider / OpenRouter targets.

<p align="center">
  <img src="./docs/assets/readme-menu-overview.png" alt="codexbar menu overview" width="452" />
</p>

### Settings and Session Records

The settings window includes account, records, usage, and update sections. The records page lets you browse local Codex sessions and jump into usage price editing.

<p align="center">
  <img src="./docs/assets/readme-records-window.png" alt="codexbar records settings window" width="1120" />
</p>

## OpenAI Usage Modes

### Manual mode

Writes the selected OpenAI OAuth account into Codex config. Use this when you want to explicitly choose one current account.

### Aggregate mode

Treats usable OpenAI OAuth accounts as a local account pool. The codexbar gateway accepts requests and routes them per session, which is useful when several accounts have quota and you want fewer manual switches.

Aggregate mode only pools OpenAI OAuth accounts. OpenRouter and custom providers do not join the aggregate pool.

### Hybrid mode

Keeps an OpenAI OAuth account as the login identity while routing actual requests to OpenRouter or a custom OpenAI-compatible provider. Use this when you already rely on a relay or OpenRouter but still want Codex plugins, MCP, remote access, and account-state-dependent behavior to keep working.

Desktop Codex sync uses stable local addresses:

- OpenAI gateway: `127.0.0.1:1456`
- OpenRouter gateway: `127.0.0.1:1457`

Mobile clients or other LAN devices should use the Mac LAN IP with the corresponding port.

## Shared Session History

`codexbar` keeps one `~/.codex` by default:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`
- `~/.codex/config.toml`
- `~/.codex/auth.json`

Switching accounts or providers only affects future requests and future sessions. Existing sessions remain in the same history pool.

## OpenRouter Management

OpenRouter supports multiple keys, multiple models, and per-key selection state:

- each OpenRouter API key can keep its own selected model and pinned model list
- new keys do not inherit another key's current model state
- editing a key can update the API key, label, and checked models
- the menu panel expands checked models as direct manual switching entries
- large model catalogs are not written into the main config, avoiding pollution in `~/.codexbar/config.json`

This is useful when you maintain several OpenRouter keys, model entry points, or purpose-specific key routes.

## Relays and Remote Access

When using a custom OpenAI-compatible provider, you can:

- route requests directly to the provider
- keep OpenAI OAuth login state through hybrid mode while routing requests to the provider
- expose the same route to mobile or remote devices through the LAN gateway

Current gateway ports:

- OpenAI gateway: `0.0.0.0:1456`
- OpenRouter gateway: `0.0.0.0:1457`

Local Codex config still writes `127.0.0.1`; mobile clients should use the Mac LAN IP instead.

## Local Usage and Cost Estimates

`codexbar` scans local session files to show token, usage, and cost estimates.

Sources:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

Token accounting:

- `input + cached_input + output`

Notes:

- this is a local usage estimate, not an official OpenAI invoice
- no remote usage is fetched or aggregated
- unpriced models count as `0` cost while token totals remain visible
- custom provider cost estimates may differ from upstream billing

## OpenAI Login

OpenAI login uses browser authorization with localhost callback capture and a manual fallback.

Steps:

1. Click the person-plus button in the menu bottom toolbar
2. Finish OpenAI authorization in the browser
3. The browser redirects to `http://localhost:1455/auth/callback?...`
4. `codexbar` captures the callback and imports the account

If automatic capture fails, paste the full callback URL or raw `code` back into the login window.

## Updates

`codexbar` checks GitHub Releases for installable stable versions:

- non-blocking update check on launch
- manual "Check for Updates" entry in the menu bar
- skips `draft`, `prerelease`, and releases without `dmg` / `zip` installer assets
- current update flow is guided download / install; the app does not replace the old app or restart itself automatically

See the update strategy:

- [docs/update-feed-rollout.md](./docs/update-feed-rollout.md)

## Build Locally

```sh
git clone https://github.com/shingex/codexbar.git
cd codexbar
open codexbar.xcodeproj
```

Then:

1. Select your signing team in Xcode
2. Build and run the `codexbar` target

If you only want to use the app, download it from [GitHub Releases](https://github.com/shingex/codexbar/releases) instead.

## Who This Is For

`codexbar` is useful if you:

- use multiple OpenAI OAuth accounts
- want Codex multi-account session history in one place instead of several `CODEX_HOME` directories
- use OpenRouter, third-party OpenAI API relays, or self-hosted OpenAI-compatible services
- want to keep Codex plugins, MCP, and account-state-dependent features working when using a relay
- need to share one Codex route across Mac, phone, and remote devices
- want local Codex token usage and cost estimates

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

## Acknowledgements

This project continues from the original `codexbar` direction and references or adapts ideas and parts of the implementation from these projects:

- [lizhelang/codexbar](https://github.com/lizhelang/codexbar)
- [xmasdong/codexbar](https://github.com/xmasdong/codexbar)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)
- [farion1231/cc-switch](https://github.com/farion1231/cc-switch)

See also:

- [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)

## License

[MIT](./LICENSE)
