---
name: codexbar
description: |
  Maintain the Codexbar repository. Use when working on OpenAI account flows, OAuth state, provider/model routing, Codex config sync, local builds, tests, or repo delivery notes.
---

# Codexbar Skill

Use this skill for Codexbar repository work, especially account state, OAuth, provider/model routing, Codex config sync, builds, tests, and delivery notes.

## Current Reality

- This repo currently has the `codexbar` app target and the `codexbarTests` test target.
- Do not assume a `codexbarctl` or other bundled CLI exists. Verify any future CLI in the repo or installed app before recommending commands.
- Account and config operations should go through the existing app/service code paths when possible.
- The local 1.8.0 release point is commit `eaff580` (`发布 1.8.0`), not a `v1.8.0` tag. Use `eaff580..v1.9.0^{}` when reviewing the 1.8.0 to 1.9.0 release range.

## Safety Rules

- Do not hand-edit `~/.codex/auth.json` or `~/.codex/config.toml` when Codexbar can perform the operation through existing code paths.
- Never print, summarize, or expose `access_token`, `refresh_token`, or `id_token`.
- If low-level repair is unavoidable, first state that the normal path is through Codexbar, then make the narrowest possible change.
- Preserve unrelated user config when changing sync behavior.

## Config Sync

- Treat `TokenStore` as the state center for active provider/account, effective gateway mode, route target, and gateway lifecycle.
- Treat `CodexSyncService` as the layer that syncs current Codexbar state into Codex `auth.json` / `config.toml`.
- Keep `switchAccount` raw config value as `switch`; user-facing copy can describe it as manual mode.
- Keep config writes minimal. Avoid mixing model provider changes, base URL changes, provider block changes, gateway routing, transport behavior, and old-config cleanup in one broad rewrite.
- Before changing `CodexSyncService` or any logic that writes Codex config/auth files, add or run regression coverage with a realistic old config sample or equivalent fixture.
- Do not delete, reorder, or overwrite unrelated existing config keys unless the task explicitly requires migration.
- Since 1.9.0, Codex-visible `model` / `review_model` and upstream provider model can differ. OpenRouter and third-party model providers route through local gateways while Codex config should keep an OpenAI-compatible visible model when needed.
- Preserve OpenAI fallback model state through `OpenAIModelStateStore`, including per-route-target snapshots. Switching to OpenRouter or third-party providers must not pollute the saved OpenAI OAuth fallback model.
- Third-party model providers must route through the OpenAI account gateway using `OpenAIAccountGatewayConfiguration.apiKey` in Codex auth. Do not write the real third-party API key into `~/.codex/auth.json`.

## Provider And Model Routing

- 1.9.0 adds first-class third-party model providers through `CodexBarThirdPartyModelProvider` (`deepseek`, `mimo`, `custom`) on top of compatible providers.
- Third-party providers use per-account `thirdPartyModelSelection`; OpenRouter continues to use per-account `openRouterSelection`. Do not collapse model selection back to provider-only state.
- `AddProviderSheet` owns the shared add/edit surface for custom OpenAI relays, third-party model providers, and OpenRouter. Avoid reintroducing separate duplicated forms for those paths.
- OpenRouter and third-party model rows in the menu should reflect the active provider, active account, and active model. A pinned or available model is not current unless it is the actual effective model for the active account.
- `ModelDisplayIdentityResolver` and `MenuBarStatusItemIconSource` drive compact model/provider identity in the menu bar. Add model-family icon/title behavior there and cover it with `MenuBarIconResolverTests` or `MenuBarStatusItemPresentationTests`.

## Gateway Adapters

- `OpenAIAccountGatewayService` is the hot path for OpenAI aggregate routing, compatible providers, OpenRouter, and 1.9.0 third-party chat-completions adapters.
- When route target is `.none`, the gateway should fail fast with a 503 instead of forwarding to an upstream by accident.
- DeepSeek and custom third-party providers use Bearer auth; MiMo uses the `api-key` header. Keep provider-specific auth/header behavior covered in `OpenAIAccountGatewayServiceTests`.
- Third-party adapters translate Codex Responses requests to `/chat/completions` and translate compact/streaming responses back to Codex-compatible responses. Keep tool calls, `apply_patch` custom tool mapping, reasoning-content filtering, and SSE completion behavior covered before changing this path.
- Avoid byte-by-byte streaming loops or high-allocation parsing in the real gateway path; use chunk/delegate based streaming and bounded accumulators for SSE transformations.

## Provider Usage And Status Item

- `ProviderUsageConfiguration` supports normalized custom request headers. Trim empty header names/values instead of persisting them.
- `ProviderUsageNormalizer` recognizes generic usage fields plus DeepSeek balance details and MiMo token-plan usage. Extend the normalizer with focused tests when adding provider-specific usage formats.
- Provider usage refreshes can start immediately, coalesce concurrent requests, and refresh all keys after account additions. Preserve those behaviors in `TokenStoreSettingsTests` / `ProviderUsageServiceTests`.
- Menu bar status presentation should prefer active-account usage snapshots and active provider model identity. Do not fall back to inactive provider usage when the active snapshot has no data.

## Menu Bar Structure

- 1.9.0 split `MenuBarView` into focused files such as `MenuBarOpenAIAccountSections.swift`, `MenuBarOpenAIModeSections.swift`, `MenuBarOpenAIChrome.swift`, and `OpenRouterMenuViews.swift`.
- Keep future menu work in the extracted section files when it belongs to account groups, mode tabs, chrome, OpenRouter, or third-party provider rows. Avoid rebuilding the previous monolithic `MenuBarView`.
- Popover sizing and scroll behavior are managed through `MenuBarStatusItemController` and `MenuBarAdaptiveScrollView`; preserve stable sizing and internal scrolling when provider/account/model lists grow.

## Codex Skills And AGENTS

- `~/.codex/skills` is a managed local skills directory. Keep skill enable/disable behavior file-based by renaming `SKILL.md` and `SKILL.md.disabled`; do not delete a skill folder just to disable it.
- New skills should have valid front matter with `name` and `description`.
- When a skill ships with a source repository, keep the provenance in the top portion of `SKILL.md` and prefer a real GitHub URL over an invented placeholder.
- Skill source discovery is heuristic. If provenance is unknown, leave it blank rather than fabricating a source URL.
- Git-backed skills can be updated from their repository URL or remote origin when available. Preserve nested skill subdirectories and do not collapse multi-skill repos into a single flat folder.
- `AGENTS.md` is actively managed by the app at launch through a generated source-rules block. Preserve user content outside the managed markers, and only replace the managed block when updating those rules.
- The skills page should stay scoped to skill management only. It should support create, search, enable/disable, update, reveal, and delete actions without mutating Codex account or config state.

## Settings And Build

- Settings pages are split by concern. Keep getting started, accounts, usage, skills, backup, and updates on separate save paths instead of funneling everything through one global save.
- Settings interactions now mix immediate actions and draft-based changes. Keep pages that only trigger one-off actions immediate, and keep pages that need confirmation behind a draft/save flow instead of forcing everything into one mode.
- The skills page is immediate-action oriented: create, search, enable/disable, update, reveal, and delete should apply directly without a draft save cycle.

## Build And Install

- Do not build `codexbar.app` automatically after low-risk repo changes.
- For new features, important logic changes, cross-module edits, build/install changes, or other higher-risk work, run a Debug build verification unless there is a clear reason not to.
- A code commit is not a local app delivery. Do not increment build number or install `/Applications/codexbar.app` for ordinary commits, PR preparation, reviews, or local validation.
- When producing a local app for real user verification, install it to `/Applications/codexbar.app` after build and required checks pass.
- For any build meant for delivery, installation, release, or real user verification, increment `CURRENT_PROJECT_VERSION` and report both version and build number.
- Do not quit, kill, or relaunch the running `codexbar` process during install; overwrite the target app and let the user reopen it.

## Tests

- The test target/module name is `codexbarTests`, not `codexBarTests`.
- When using `xcodebuild -only-testing`, write filters as `-only-testing:codexbarTests/...`.
- If a test filter fails because the scheme or test plan cannot find the target, inspect `xcodebuild -list` and the current scheme/test plan before retrying.

## Delivery Notes

At the end of a completed task, state:

1. Which files changed.
2. What each file does.
3. How the core logic was implemented.
4. Why it was implemented that way.
5. How the user can manually verify it.

If no test or verification command was run, say that explicitly.
