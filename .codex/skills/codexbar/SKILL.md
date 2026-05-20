---
name: codexbar
description: |
  Maintain the Codexbar repository. Use when working on OpenAI account flows, OAuth state, Codex config sync, local builds, tests, or repo delivery notes.
---

# Codexbar Skill

Use this skill for Codexbar repository work, especially account state, OAuth, Codex config sync, builds, tests, and delivery notes.

## Current Reality

- This repo currently has the `codexbar` app target and the `codexbarTests` test target.
- Do not assume a `codexbarctl` or other bundled CLI exists. Verify any future CLI in the repo or installed app before recommending commands.
- Account and config operations should go through the existing app/service code paths when possible.

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

## Build And Install

- Do not build `codexbar.app` automatically after ordinary repo changes.
- Build, install, or deliver the app only when the user explicitly asks for build/install/delivery/release, or when the task is itself about build/install failure or a major runtime bug.
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
