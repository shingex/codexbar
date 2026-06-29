# Product Marketing Context

*Last updated: 2026-06-29*

## Product Overview
**One-liner:** CodexBar is a macOS menu bar control center for Codex accounts, gateways, models, usage, session history, and Skills.

**What it does:** CodexBar keeps Codex Desktop / Codex CLI on one shared `~/.codex` while giving users a visual way to switch OpenAI OAuth accounts, OpenRouter keys, and third-party OpenAI-compatible relays. It also adds cross-account session history, usage and reset-credit visibility, local backup/restore, Skill management, and gateway enhancements such as Headroom-style compression and Retry Gateway 516 handling.

**Product category:** Codex account switcher, Codex gateway manager, Codex OpenRouter tool, Codex usage tracker, Codex session history manager, Codex Skill manager.

**Product type:** Open-source macOS desktop utility.

**Business model:** Free and open source.

## Target Audience
**Target companies:** Individual developers, AI coding power users, indie hackers, small technical teams, and Mac users already using Codex Desktop / Codex CLI.

**Decision-makers:** Individual developer-users; for small teams, the developer who owns local AI coding setup and model/provider routing.

**Primary use case:** Make Codex easier to operate when one user has multiple accounts, multiple providers, or multiple gateways.

**Jobs to be done:**
- Switch Codex accounts, OpenRouter models, and relays without manually editing `~/.codex/config.toml` or splitting `CODEX_HOME`.
- Keep Codex session history searchable and manageable across accounts and providers.
- Understand usage, reset credits, provider quotas, and token-saving gateway behavior from one local UI.

**Use cases:**
- Replace a CLI-only account switcher with a visual macOS menu bar control center.
- Use OpenRouter or an OpenAI-compatible relay while preserving Codex account-state-dependent behavior.
- Review and delete local Codex sessions without browsing JSONL files manually.
- Manage local Codex Skills from a UI instead of editing `~/.codex/skills` by hand.

## Personas
| Persona | Cares about | Challenge | Value we promise |
|---------|-------------|-----------|------------------|
| Codex power user | Fast switching, stable sessions, less config work | Multiple accounts and providers make Codex fragile | A visual control center that keeps one shared Codex home |
| OpenRouter / relay user | Third-party models and API routes | Direct config changes can break plugins, MCP, or account-state behavior | Hybrid routing keeps OpenAI login state while routing requests elsewhere |
| Skill-heavy Codex user | Discoverable local Skill maintenance | Skills are scattered in folders and hard to update safely | Search, inspect, enable, disable, update, create, and delete Skills from one page |

## Problems & Pain Points
**Core problem:** Codex is powerful, but multi-account, OpenRouter, relay, usage, session, and Skill operations are fragmented across config files, folders, terminal commands, and local history files.

**Why alternatives fall short:**
- CLI switchers can be fast but are less visual and often focus narrowly on account switching.
- Manual `config.toml` edits are brittle and easy to forget.
- Separate `CODEX_HOME` setups split history and make resume workflows harder.
- Generic API gateway tools do not understand Codex session history, Skills, reset credits, or local config sync.

**What it costs them:** Time spent switching context, broken sessions, scattered history, uncertainty about usage, and repeated local config maintenance.

**Emotional tension:** Power users want to bend Codex to their workflow without feeling that every provider or account change may break the setup.

## Competitive Landscape
**Direct:** CCSwitch / cc-switch style tools - strong for quick switching, but CodexBar differentiates with a visual macOS UI, cross-account history, usage views, Skill management, and gateway enhancements.

**Secondary:** Manual Codex config editing - flexible but error-prone and not discoverable.

**Indirect:** Generic OpenAI-compatible gateways - useful for routing, but not built around Codex Desktop / CLI state, history, Skills, and account modes.

## Differentiation
**Key differentiators:**
- Visual account, OpenRouter, and relay switching from the macOS menu bar.
- One shared `~/.codex` with cross-account session history and delete support.
- Usage, provider quota, and official reset-credit visibility in the same UI.
- Local `~/.codex/skills` management with source/update workflows.
- Built-in gateway enhancements for Headroom-style compression and Retry Gateway 516 handling.

**How we do it differently:** CodexBar manages Codex-facing config as a local state boundary instead of asking users to maintain separate homes or hand-edit provider settings.

**Why that's better:** Users keep the Codex workflow they already know, but gain a single control surface for switching, routing, usage, history, and Skills.

**Why customers choose us:** They already use Codex and want a focused Codex-native utility rather than a generic model gateway or a narrow account switcher.

## Objections
| Objection | Response |
|-----------|----------|
| I can already edit config files myself. | CodexBar is for users who want repeatable switching, shared history, usage visibility, backup, and Skill management without hand-editing every time. |
| I only need a simple switcher. | CodexBar can act as a switcher, but it also covers the surrounding Codex workflow: history, usage, gateway behavior, and Skills. |
| I do not want cloud sync for my keys. | Accounts, keys, providers, backups, usage scans, and history stay local. |

**Anti-persona:** Users who do not use Codex Desktop / Codex CLI, do not use macOS, or only need a generic API gateway unrelated to Codex.

## Switching Dynamics
**Push:** Manual config edits, split `CODEX_HOME` directories, fragile relay setup, unclear usage, and hard-to-maintain Skills.

**Pull:** One menu bar control center for the full Codex operating surface.

**Habit:** Users may already have shell scripts, aliases, or manual routines.

**Anxiety:** Users may worry about secrets, breaking Codex config, or whether gateway routing changes official behavior.

## Customer Language
**How they describe the problem:**
- "I need to switch Codex accounts without losing history."
- "I want to use OpenRouter with Codex but keep the Codex features working."
- "I want to see Codex usage and reset counts in one place."
- "I have too many Skills and do not want to manage folders manually."

**How they describe us:**
- "A Codex account switcher with a real UI."
- "A Codex gateway manager for OpenRouter and relays."
- "A Codex control center for history, usage, and Skills."

**Words to use:** Codex account switcher, Codex gateway, OpenRouter for Codex, OpenAI-compatible relay, Codex usage tracker, Codex history manager, Codex Skills manager, macOS menu bar.

**Words to avoid:** generic AI launcher, generic chatbot app, cloud key manager.

**Glossary:**
| Term | Meaning |
|------|---------|
| `~/.codex` | Codex local config, auth, session, archive, and Skill root |
| Hybrid mode | Keep OpenAI OAuth identity while routing requests to OpenRouter or another OpenAI-compatible provider |
| Aggregate mode | Pool OpenAI OAuth accounts behind the local CodexBar gateway |
| Relay / provider | A third-party OpenAI-compatible API endpoint |
| 516 guard | Gateway behavior that intercepts configured reasoning-token failure patterns and returns a retryable response |

## Brand Voice
**Tone:** Technical, direct, practical.

**Style:** Clear product claims backed by exact Codex paths, modes, and local behavior.

**Personality:** Useful, local-first, power-user friendly, precise.

## Proof Points
**Metrics:** Not yet established publicly.

**Customers:** Not yet established publicly.

**Testimonials:** None captured yet.

**Value themes:**
| Theme | Proof |
|-------|-------|
| Local-first | Accounts, keys, providers, backups, and usage scans stay on the user's Mac |
| Codex-native | Works around `~/.codex`, `auth.json`, `config.toml`, sessions, archived sessions, and Skills |
| Broader than switching | Covers account/provider/model switching, history, usage, reset credits, backups, Skills, and gateway behavior |

## Goals
**Business goal:** Increase discovery among Codex Desktop / CLI users who need account switching, OpenRouter, relay, usage, history, Skill, or gateway workflows.

**Conversion action:** Visit GitHub, understand the value in under 10 seconds, download the latest release, and star/watch the repository.

**Current metrics:** User reported that the main issue is awareness and discovery, not product capability.
