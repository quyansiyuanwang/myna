# Project context — myna (Myna)

- GitHub: https://github.com/quyansiyuanwang/myna
- Product: `Myna` — a native macOS menu-bar assistant (SwiftPM only, no Xcode project).
- **Owner username: `quyansiyuanwang`.** Use it in every URL, badge, and
  `Package.swift` example. Never write `<owner>` or any other placeholder.
- Runtime: talks directly to the LLM (DeepSeek, OpenAI-compatible) via the
  `PiKit` product from `pi-kit-swift`. **Zero Node.js at runtime.**
- `agent_runtime` modes: `auto` / `package` / `builtin`.
- Multi-model support: `AppSettings` flat fields are the live config; `modelProfiles`
  stores named snapshots applied via `SettingsStore.selectProfile(id:)`. Model ids can
  be discovered per protocol with `ModelDiscovery` (`myna models`). Reasoning settings
  (`reasoning_effort`, `thinking_budget`) are injected in `PackageRuntime.makeProvider`
  and must stay in `ChatModel.packageSignatureValue` so the agent rebuilds.
- Swift 6 strict concurrency, zero warnings; build with
  `swift build -Xswiftc -warnings-as-errors`.
- Build/bundle with `./build.sh`; CLI symlink at `~/.local/bin/myna`.
- Docs: professional/technical tone, no emoji, no colloquialisms.
- **Temporary artefacts never enter the repository.** Scratch scripts, task briefs,
  captured logs and probe output go to `.tmp/` (gitignored) or `/tmp`. Do not run commands
  that redirect output into the working tree (e.g. `cmd > 0`); that has already produced a
  tracked file named `0` once.

## Self-control and self-extension

- `SelfControlAPI` (`Sources/Myna/SelfControl.swift`) is the single implementation of
  the self-control surface. CLI: `myna api <group.action> [json]`; tools:
  `myna_settings`, `myna_permissions`, `myna_data`, `skill_write`, `skill_delete`,
  `mcp_manage`, `plugin_manage`.
- Config writes are validated by decoding the merged JSON back into `AppSettings`,
  re-encoding it and comparing the value for that key. A mismatch is rejected.
  Every write backs up to `~/.config/myna/backups/config-<timestamp>.json` first.
- Settings mutations happen off the main thread. Never use `DispatchQueue.main.sync`
  from a tool: the CLI `agent` command blocks the main thread while the agent runs,
  so `main.sync` deadlocks. Use the bounded `runOnMainWithTimeout` helper instead.
- Local plugins are JSON manifests in `~/.config/myna/plugins/<id>.json`
  (`LocalPlugin`). Enabled plugins append `instructions` to the system prompt.
  Skills live in `~/.config/myna/skills/<id>/SKILL.md` and are listed in the prompt.
- After mutating skills / plugins / MCP / config, post
  `Notification.Name.mynaResourcesChanged`. `ChatModel.invalidateAgents()` clears the
  agent signature so the next prompt rebuilds with the new prompt and tools while
  keeping the transcript.
- `LocalResources.configDir` follows `MYNA_CONFIG`; skills, plugins, profiles,
  backups and screenshots stay inside the isolated directory during tests.

## Computer use

- `ComputerUse` (`Sources/Myna/ComputerUse.swift`): `screenshot`, `read_screen`
  (Vision OCR), `list_windows`, `activate_app`, `mouse_move`, `mouse_click`,
  `mouse_drag`, `scroll`, `key_press`, `type_text`, `wait`, `view_image`.
- Screen tools require Screen Recording; mouse/keyboard require Accessibility.
  Tools return an actionable message when permission is missing. The user grants
  permissions in System Settings; they cannot be granted programmatically.
- `screenshot` / `read_screen` must never assume a screen scale. Coordinates are
  global display points with a top-left origin; screenshots are pixels.
- `view_image` returns a PiAI image block only when the current model declares
  `supports_vision`; otherwise it returns a path and points at `read_screen`.
- DeepSeek endpoints (`api.deepseek.com`) default models to vision-capable;
  configs without an explicit `supports_vision` key are migrated once on load.
  Do not re-enable after an explicit `false`.
- `ToolRunner.packageTools` special-cases `view_image` so the tool result carries
  `.image(ImageContent)`. OpenAI Chat Completions is patched upstream (pi-ai-swift
  0.1.7) to send tool-result images as a follow-up user message.

## Tool count and checks

- 61 built-in tools (44 original + 7 self-control + 12 computer use, minus overlaps).
  `myna tools` is the source of truth; update docs when it changes.
- New self-checks: `myna self-check` (isolated config; 21 assertions) and
  `myna computer-check` (18 assertions; real capture only when already authorized).
