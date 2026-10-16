# Myna

[![CI](https://github.com/quyansiyuanwang/myna/actions/workflows/ci.yml/badge.svg)](https://github.com/quyansiyuanwang/myna/actions/workflows/ci.yml)

A native macOS menu bar assistant powered by a large language model. It supports
direct voice conversation and exposes a set of local system actions (application
control, media, reminders, calendar, and more) that the model can invoke as tools.

Written in Swift. Builds with the Swift toolchain only — no Xcode project required.

- LLM backend: any endpoint implementing one of four API protocols —
  `openai-completions`, `openai-responses`, `anthropic-messages`,
  `google-generative-ai` (Gemini); all four are implemented natively in the
  `pi-ai-swift` port. The configuration names the **protocol**, not the vendor
- Multiple saved model profiles (Settings → 模型 → 模型列表) with per-protocol
  reasoning settings; switch profiles from the window header without re-entering
  the API key. Model discovery probes the configured endpoint for available
  model ids (the **探测模型** button, or `myna models`)
- Voice input via the Speech framework, speech output via AVSpeechSynthesizer
- Global hotkey (default `Option+Space`) to open the window and start listening
- 40+ local tools for controlling macOS, plus coding-agent capabilities: file
  read/write/edit, directory listing, glob and content search, Git status/diff/
  log/commit, and a general `run_command` escape hatch for builds and tests.
  `run_subagent` / `run_subagents` delegate self-contained tasks to fresh agents
  with isolated context and run several sub-agents in parallel
- Coding mode (`coding_mode`) appends a senior-engineer addendum to the system
  prompt; a configurable working directory (`working_directory`) is the base for
  every relative path, with configurable read-size, output-length and timeout limits
- Unlimited tool rounds per prompt (set `max_tool_rounds` to `0` or enable
  `unlimited_tool_rounds`) so long multi-step tasks are not cut off
- Each conversation runs independently: a reply keeps streaming when you switch
  conversations or close the panel, and several conversations can run in parallel.
  Conversations that are still running show a spinner and a stop button in the
  conversation panel
- Optional MCP (Model Context Protocol) servers over stdio, exposed to the
  model as `mcp__<server>__<tool>` tools
- In-app marketplace (Settings → 市场) that installs community skills, MCP
  servers and plugins from the [myna-hub](https://github.com/quyansiyuanwang/myna-hub)
  registry
- Skills are read from `~/.config/myna/skills` and from the pi agent directory
  `~/.pi/agent/skills`
- Full settings UI; API key, model, voice, conversation, tools and hotkey are configurable
- Agent runtime linked directly against the Swift composition layer
  [`pi-kit-swift`](https://github.com/quyansiyuanwang/pi-kit-swift) (which
  re-exports `PiAI` and `PiAgentCore`) — **no Node.js and no extra child
  processes at runtime**

## Install

### Homebrew (recommended)

```bash
brew install --cask quyansiyuanwang/tap/myna
```

The cask installs `Myna.app` to `/Applications` and strips the quarantine
attribute so it launches without a Gatekeeper prompt.

### Download

Download `Myna-v<version>.zip` from the
[releases](https://github.com/quyansiyuanwang/myna/releases) page,
move `Myna.app` to `/Applications`, then clear the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/Myna.app
```

Alternatively, right-click the app and choose **Open** the first time.

### Build from source

See [Build and install](#build-and-install) below.

## Requirements

- macOS 13 or later (developed on macOS 15)
- Swift toolchain (`swift`). If missing, install the Command Line Tools:
  `xcode-select --install`
- An API key for the provider you point it at

The agent runtime is compiled into the binary from the `pi-kit-swift` Swift
package (pinned to `0.1.7`), which re-exports `PiAI` and `PiAgentCore`. Node.js
is **not** required, at build time or at runtime.

## Build and install

```bash
./build.sh
```

This compiles a release binary and produces:

| Path | Description |
|---|---|
| `~/Applications/Myna.app` | The menu bar application |
| `~/.local/bin/myna` | Command-line interface (symlink to the app binary) |
| `~/.config/myna/config.json` | Configuration file (created from `config.example.json`) |

`./build.sh` ad-hoc code-signs the app (`codesign --sign -`), which is sufficient for
local use and requires no developer account. If a **Developer ID Application**
certificate is present in the keychain, `build.sh` signs with it automatically
(hardened runtime + timestamp). To verify the signature:

```bash
codesign --verify --verbose ~/Applications/Myna.app
```

For a distributable, notarized build, use `./release.sh <version>`. See
[`docs/SIGNING.md`](docs/SIGNING.md) for obtaining a Developer ID certificate and
storing notarization credentials.

## Usage

Click the menu bar icon or press the global hotkey to open the chat window. The window
is resizable, remembers its position, and keeps multi-turn conversation context.

### Voice interaction

1. Press `Option+Space` (configurable) or click the microphone button to start recording.
2. The live transcription appears in a status line and does not overwrite the input field.
3. After roughly 1.5 seconds of silence, recording stops automatically.
4. Press the global hotkey again to stop recording at any time. The hotkey acts as a
toggle: it starts listening when idle and finishes the recording when active. By default
it also sends the message immediately (`hotkey_auto_send`); the microphone button stops
without sending so the text can still be edited.
5. The transcription is appended to the input field.
6. Press Enter to send. Pressing Enter while recording stops the recording and sends.
7. Sending releases the microphone immediately; the reply is streamed and spoken.

Transcription and the input field are kept separate, so editing the text and continuing to
speak does not duplicate or overwrite previous content.

### Prompts and skills

Myna reads two local resource directories (created on first launch), plus the
pi agent skill directory if it exists:

```
~/.config/myna/prompts/*.md            # prompt templates
~/.config/myna/skills/<name>/SKILL.md  # skills
~/.pi/agent/skills/<name>/SKILL.md     # pi agent skills (optional)
```

**Prompt templates** appear in the input bar's prompt menu; clicking one inserts its
content into the input field (it is not sent automatically). An optional first line
`# Title` is used as the menu label.

**Skills** use optional YAML frontmatter:

```markdown
---
name: 日报生成
description: 汇总今天的提醒与日程，生成一段日报文本
---
具体步骤……
```

The skill's name and description are appended to the system prompt, and the model can
read the full instructions with the `read_skill` tool (`list_skills` lists them).

Skills found in `~/.pi/agent/skills` use the same `<name>/SKILL.md` layout and are
merged with the Myna skills. If the same id exists in both directories, the
`~/.config/myna/skills` copy takes precedence.

### Marketplace

Settings → **市场** installs community resources from the
[myna-hub](https://github.com/quyansiyuanwang/myna-hub) registry. The registry is
fetched at runtime from
`https://raw.githubusercontent.com/quyansiyuanwang/myna-hub/main/registry.json`.

The section has three sub-sections:

- **技能** — downloads `<path>/SKILL.md` into `~/.config/myna/skills/<id>/`
- **MCP** — downloads `<path>/mcp.json`, merges the server entry into
  `~/.config/myna/mcp.json`, and reloads the MCP manager
- **插件** — installs every referenced skill and MCP

Each row has an install/uninstall button with per-item progress, and a search
field filters all three lists. The same registry is reachable from the command
line with the hidden maintenance command `myna market-install <skill|mcp|plugin> <id>`.
Set `MYNA_HUB_BASE` to point at a mirror or a local `file://` checkout for
offline testing.

A status-bar menu item **市场…** opens Settings directly on this section.

### Icon

The app icon (`Resources/Myna.icns`) is a 3D woven-ribbon "m". The menu bar uses a
simplified monochrome version (`Resources/MenuBarTemplate.png`, a template image so it
adapts to light and dark menu bars); pick it under **Settings → 行为 → 菜单栏图标 →
自定义图案**, or choose an SF Symbol instead.

### Window mode

Myna opens as a **drop-down panel** by default: an `NSPopover` anchored to the menu bar
icon, expanding downward. It closes automatically when you click outside it or when the
app is deactivated, and Escape also closes it. Opening Settings dismisses the panel first
so the settings window is never covered. Turn **下拉面板模式** off in
Settings → 行为 to use a normal, movable, resizable window instead.

### Continuous mode

Enable **Continuous** in the window header. After each spoken reply finishes, the assistant
starts listening again, allowing a fully voice-driven exchange. Closing the window stops
automatic listening.

### Conversations

Myna keeps multiple conversations. The list button in the window header opens a panel to:

- switch between conversations (the most recent one is restored on launch)
- start a new conversation
- rename or delete a conversation (per-row buttons, or right-click for a context menu)
- export a conversation to JSON
- import a conversation from JSON (inserted as a new conversation)

The panel also has a **full-text search** field: it searches every conversation and
lists matching messages with a snippet; clicking a hit switches to that conversation,
scrolls to the message and highlights it briefly.

Each conversation stores its own transcript. Switching rebuilds the agent context for
both runtimes — the Swift-package runtime restores it through `Agent.setTranscript`.
Conversations are persisted to `~/.config/myna/conversations.json`.

### Background and parallel runs

With **Settings → 对话 → 运行 → 切换会话时后台继续运行** enabled (the default), each
conversation keeps its own agent and run; switching conversations or closing the panel
does not interrupt a reply. Several conversations can run at the same time, up to
**并行运行上限** (`max_parallel_runs`, default `3`). When the limit is reached, starting
a new run stops the oldest running conversation and leaves a short notice in it. Turn
the setting off to restore the previous behaviour, where switching conversations cancels
the current run. The conversation panel lists running conversations with a spinner and a
stop button, and the header shows `N 个会话在后台运行` when the current conversation is
idle but others are still running.

### Message display

Reasoning and tool activity are shown as collapsible blocks, similar to the pi CLI:

- **思考 / thinking** — the model's reasoning stream, rendered as a collapsed block
- **工具 / tools** — each tool call and its result, rendered as a collapsed block

Click a block header to expand or collapse it. Visibility and default state are
configurable under **Settings → 对话 → 显示内容**:

| Setting | Default | Effect |
|---|---|---|
| `show_thinking` | `true` | Show reasoning blocks |
| `show_tool_calls` | `true` | Show tool-call blocks |
| `collapse_thinking` | `true` | Reasoning blocks start collapsed |
| `collapse_tools` | `true` | Tool blocks start collapsed |

These are applied at render time, so toggling them immediately shows or hides
**existing** messages, not just new ones.

### Coding tools and coding mode

Myna exposes a coding-agent tool set on top of the macOS control tools. All
paths accept `~`, and relative paths resolve against **Settings → 工具 → 工作目录**
(`working_directory`, default: the user's home directory).

| Tool | Description |
|---|---|
| `read_file` | Read a text file with `   1 \| …` line numbers; optional `offset` / `limit` line window |
| `write_file` | Write a file, optionally creating parent directories |
| `edit_file` | Exact string replacement; errors on a missing or ambiguous `old_string` unless `replace_all` is set |
| `list_dir` | List a directory (directories first, with type and size) |
| `find_files` | Glob search (`*`, `?`, `**`) |
| `search_text` | Recursive content search, output as `file:line: text` |
| `make_dir` | Create a directory (including parents) |
| `move_path` | Move or rename a file / directory |
| `delete_path` | Delete a file or directory (dangerous) |
| `git_status` | Repository status and branch |
| `git_diff` | Working-tree or staged diff (`git diff [--staged]`) |
| `git_log` | One-line commit history |
| `git_commit` | Stage and commit changes (dangerous) |
| `run_command` | Run a shell command for builds/tests, with a configurable output cap and timeout (dangerous) |

**Coding mode** (`coding_mode`) appends a coding-oriented addendum to the system
prompt: act as a senior engineer, inspect the code and project structure before
editing, prefer small precise edits, run builds/tests after changes, never invent
file contents, stay inside the working directory, and summarise what changed.
Because coding tasks take many tool rounds, the settings pane suggests (but does
not force) raising `max_tool_rounds` or enabling `unlimited_tool_rounds`.

**Dangerous tools** (`delete_path`, `git_commit`, `run_command`, plus
`shell_command` and `run_applescript`) are flagged in the settings list. With
`confirm_dangerous_tools` enabled, they refuse to run and return a message asking
the model to obtain explicit user confirmation first; the app has no modal prompt,
so the switch is the documented confirmation mechanism.

## Configuration

Open **Settings** from the menu bar context menu, the gear button in the window, or `Cmd+,`.
Changes are saved immediately to `~/.config/myna/config.json` (mode `0600`).

### Settings reference

The settings window uses a sidebar with the following sections:

| Section | Options |
|---|---|
| Appearance | Theme (system/light/dark), accent color, font size, density (compact/comfortable), bubble corner radius, avatars, timestamps, Markdown rendering, window opacity, default window size |
| Model | API protocol, API base URL, API key, model (with **探测模型** discovery), saved model profiles (create/update/duplicate/delete/apply, inline rename), connection test; agent runtime; temperature, top-p, frequency penalty, presence penalty, max tokens, retry count; per-protocol reasoning effort / thinking budget; system prompt; unlimited tool rounds; retained history turns; sub-agent timeout / max rounds / parallel limit |
| Voice | Speak replies, speak tool results, language, voice, rate, volume, pitch, preview; silence timeout, no-speech timeout, auto-send on silence, listen cue |
| Chat | Continuous mode, background runs and parallel-run limit, show tool calls, auto-scroll, clear on close, send-on-Enter, retained history turns |
| Behavior | Global hotkey (record any combination or pick a preset), menu bar icon, always-on-top, launch at login, show in Dock, open config file, restore defaults |
| Tools | Coding mode, working directory (with a folder picker), read-size / output-length / command-timeout limits, dangerous-tool confirmation, search, enable/disable all, per-tool toggles with danger flags |

### Config file fields

| Key | Type | Default | Description |
|---|---|---|---|
| `base_url` | string | `https://api.deepseek.com` | API base URL |
| `api` | string | `openai-completions` | API protocol: `openai-completions`, `openai-responses`, `anthropic-messages`, `google-generative-ai` |
| `api_key` | string | `""` | Provider API key |
| `model` | string | `deepseek-flash` | Model identifier (free-form) |
| `model_profiles` | object[] | `[]` | Saved multi-model profiles (see below) |
| `active_profile_id` | string\|null | `null` | UUID of the applied profile |
| `reasoning_effort` | string | `""` | `openai-responses` reasoning effort: empty (off), `minimal`, `low`, `medium`, `high`, `xhigh`, `max` |
| `thinking_budget` | int | `0` | Thinking budget tokens (0 = off) for `anthropic-messages` and `google-generative-ai` |
| `max_tokens` | int | `8192` | Maximum output tokens |
| `temperature` | double | `0.7` | Sampling temperature |
| `top_p` | double | `1.0` | Nucleus sampling |
| `frequency_penalty` | double | `0.0` | Frequency penalty |
| `presence_penalty` | double | `0.0` | Presence penalty |
| `max_retries` | int | `2` | Retry attempts on network errors and 429/5xx (both runtimes) |
| `max_tool_rounds` | int | `8` | Maximum tool-execution rounds per prompt; `0` = unlimited |
| `unlimited_tool_rounds` | bool | `false` | Ignore `max_tool_rounds` and allow unlimited tool rounds |
| `subagent_timeout_seconds` | int | `300` | Timeout for a single sub-agent run (seconds) |
| `subagent_max_rounds` | int | `16` | Maximum tool-execution rounds for a sub-agent |
| `subagent_max_parallel` | int | `3` | Maximum number of concurrent `run_subagents` sub-agents |
| `working_directory` | string | `""` | Base directory for the file / Git tools; empty = user home directory |
| `coding_mode` | bool | `false` | Append a coding-oriented addendum to the system prompt |
| `max_read_bytes` | int | `1048576` | Maximum bytes read per file by `read_file` and `search_text` |
| `command_timeout_seconds` | int | `120` | Default timeout for `run_command` and Git tools (seconds) |
| `max_output_chars` | int | `20000` | Maximum characters returned to the model by `run_command` and the Git tools |
| `confirm_dangerous_tools` | bool | `false` | When true, dangerous tools refuse to run until the user confirms and turns the switch off |
| `system_prompt` | string | built-in | System prompt |
| `appearance` | string | `system` | `system`, `light`, or `dark` |
| `accent` | string | `blue` | `blue`/`purple`/`pink`/`red`/`orange`/`yellow`/`green`/`graphite` |
| `font_size` | double | `13.0` | Chat font size (pt) |
| `density` | string | `comfortable` | `compact` or `comfortable` |
| `show_timestamps` | bool | `false` | Show message timestamps |
| `show_avatars` | bool | `true` | Show role avatars and names |
| `markdown_enabled` | bool | `true` | Render Markdown and code blocks |
| `window_opacity` | double | `1.0` | Window opacity (0.7–1.0) |
| `bubble_corner_radius` | double | `12.0` | Message bubble corner radius |
| `window_width` | double | `480` | Default window width |
| `window_height` | double | `700` | Default window height |
| `voice_enabled` | bool | `true` | Speak replies |
| `voice_language` | string | `zh-CN` | Speech recognition and synthesis language |
| `voice_name` | string | `""` | Voice identifier; empty uses the language default |
| `voice_rate` | double | `0.5` | Speech rate |
| `voice_volume` | double | `1.0` | Speech volume |
| `voice_pitch` | double | `1.0` | Speech pitch multiplier |
| `speak_tool_results` | bool | `false` | Speak tool results aloud |
| `silence_timeout` | double | `1.5` | Seconds of silence that end recording |
| `no_speech_timeout` | double | `8.0` | Seconds without speech before giving up |
| `auto_send_on_silence` | bool | `false` | Send automatically when recording ends |
| `continuous_mode` | bool | `false` | Listen again after each spoken reply |
| `listen_sound` | bool | `true` | Play a cue when recording starts/stops |
| `hotkey_auto_send` | bool | `true` | Pressing the hotkey again stops recording and sends |
| `send_on_enter` | bool | `true` | Enter sends; when off, Enter inserts a newline and Cmd+Enter sends |
| `auto_scroll` | bool | `true` | Scroll to the newest message |
| `max_history_turns` | int | `20` | Retained user turns (0 = unlimited) |
| `clear_on_close` | bool | `false` | Clear the transcript when the window closes |
| `background_runs` | bool | `true` | Keep conversations running when you switch away or close the panel; when `false`, switching cancels the current run |
| `max_parallel_runs` | int | `3` | Maximum number of conversations running at once; exceeding it stops the oldest run |
| `hotkey` | string | `option+space` | Global hotkey. Record any combination in Settings, or write one directly, e.g. `control+option+k`, `command+shift+/`, `f5`. Must include a modifier (or be an F-key). A combination already taken by another app is reported as a conflict. A double-tap modifier is also supported: `double:option`, `double:control`, `double:command`, `double:shift` (requires Accessibility permission) |
| `hotkey_mode` | string | `toggle` | `toggle` (press to start, press again to stop) or `pushToTalk` (hold to talk, release to send) |
| `hotkey_open` | string | `""` | Optional extra hotkey that only opens the window (no listening) |
| `hotkey_clear` | string | `""` | Optional extra hotkey that clears the conversation |
| `menu_bar_icon` | string | `brain.head.profile` | SF Symbol name for the menu bar icon |
| `show_tool_calls` | bool | `true` | Show tool invocations in the transcript |
| `show_thinking` | bool | `true` | Show reasoning blocks |
| `collapse_thinking` | bool | `true` | Reasoning blocks start collapsed |
| `collapse_tools` | bool | `true` | Tool blocks start collapsed |
| `always_on_top` | bool | `false` | Keep the window above other windows |
| `launch_at_login` | bool | `true` | Register a login item |
| `show_in_dock` | bool | `false` | Show an icon in the Dock |
| `agent_runtime` | string | `auto` | Backend: `auto` (Swift package), `package`, or `builtin` (legacy `pi` maps to `package`) |
| `disabled_tools` | string[] | `[]` | Tool names the model may not use |

The flat `base_url` / `api_key` / `model` / `api` / `reasoning_effort` /
`thinking_budget` / `max_tokens` / `temperature` fields are always the **live**
configuration. Each entry in `model_profiles` stores a snapshot with the same
snake_case keys (`id`, `name`, `base_url`, `api_key`, `model`, `api`,
`reasoning_effort`, `thinking_budget`, `max_tokens`, `temperature`); applying a
profile copies its values into the flat fields and sets `active_profile_id`.
Editing a flat field never modifies a saved profile. Missing keys fall back to
defaults, so configuration files written by older versions keep working.

### Environment variables

Environment variables override the config file:

| Variable | Overrides |
|---|---|
| `DEEPSEEK_API_KEY` | `api_key` |
| `MYNA_BASE_URL` | `base_url` |
| `MYNA_MODEL` | `model` |
| `MYNA_MCP_CONFIG` | Path to the MCP configuration file (default `~/.config/myna/mcp.json`) |
| `MYNA_HUB_BASE` | Base URL of the marketplace registry (default the myna-hub `main` branch) |

## Command-line interface

```bash
myna ask "打开计算器，把音量调到30"     # built-in runtime
myna agent "现在几点？"                 # Swift-package agent runtime (PiKit)
myna tool get_datetime                  # run a single tool
myna tool open_app '{"name":"计算器"}'
myna tools                              # list all tools
myna models                             # discover model ids at the configured endpoint
myna market-install skill daily-report  # install from the community registry (hidden)
```

`myna ask` also reads the prompt from stdin when no argument is given.

## Agent runtime

The assistant supports two backends, selected by the `agent_runtime` setting:

| Value | Backend |
|---|---|
| `auto` (default) | The Swift-package runtime |
| `package` | Swift-package runtime built on [`pi-kit-swift`](https://github.com/quyansiyuanwang/pi-kit-swift) |
| `builtin` | Hand-written Swift streaming client and tool-call loop |

The package runtime links `PiKit` (the composition layer over
`PiAI` and `PiAgentCore`) directly into the app. It streams chat completions,
owns the assistant ↔ tool loop, and exposes the same local tool implementations
(`ToolRunner`) through `PiKit.FunctionTool`. Everything runs in-process:
**no Node.js, no sidecar, no extra child process.** Settings for the model,
system prompt and disabled tools are applied by rebuilding the agent; the
conversation transcript is preserved while those settings are unchanged.

The built-in backend remains as a dependency-free fallback and is selected with
`agent_runtime = "builtin"`; it shares the same tool set and UI.

## MCP servers

Myna can also load tools from external [Model Context Protocol](https://modelcontextprotocol.io)
servers over stdio. Servers are declared in `~/.config/myna/mcp.json` (created
on first run); their tools are namespaced as `mcp__<server>__<tool>` and can be
enabled or disabled individually in Settings. Servers start asynchronously
after launch and are terminated on quit.

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "env": {}
    }
  }
}
```

See [docs/MCP.md](docs/MCP.md) for the full format, the CLI usage
(`myna tool mcp__filesystem__read_file '{"path":"/tmp/x"}'`), and the
self-test script `scripts/mcp-selftest.sh`.

## Permissions

macOS prompts on first use of each capability:

| Capability | Permission |
|---|---|
| Voice input | Microphone, Speech Recognition |
| Music, Reminders, Calendar | Automation |
| Brightness, lock screen, simulated input | Accessibility |

If a tool reports a timeout, grant the corresponding permission in
System Settings → Privacy & Security.

## Architecture

```
Myna/
├── Sources/Myna/
│   ├── main.swift           # GUI / CLI entry point
│   ├── AppDelegate.swift    # menu bar item, windows, main menu, hotkeys, login item
│   ├── ChatView.swift       # chat window, streaming rendering, transcription
│   ├── SettingsView.swift   # settings (sidebar layout)
│   ├── Config.swift         # AppSettings model and SettingsStore
│   ├── Conversations.swift  # conversation model, store, export/import
│   ├── Theme.swift          # appearance, accent, density, role model
│   ├── Models.swift         # model suggestions for the quick switcher
│   ├── ModelProfiles.swift  # saved model profiles and CRUD helpers
│   ├── ModelDiscovery.swift # probe endpoint for available model ids
│   ├── AIClient.swift       # built-in (fallback) streaming client and tool-call loop
│   ├── PackageRuntime.swift # Swift-package runtime (PiKit.AgentKit + AgentConfiguration)
│   ├── Tools.swift          # local tool implementations + PiKit.FunctionTool adapter
│   ├── CodingTools.swift    # file / directory / search / Git / run_command tools
│   ├── SubAgent.swift       # run_subagent / run_subagents runner (async + bounded blocking)
│   ├── MCPClient.swift      # MCP JSON-RPC client over stdio (single server)
│   ├── MCPManager.swift     # loads mcp.json, starts servers, namespaces tools
│   ├── Marketplace.swift    # community hub: registry, install/uninstall, UI state
│   ├── Speech.swift         # speech recognition (silence detection) and synthesis
│   ├── HotKey.swift         # global hotkeys: recorder, double-tap, push-to-talk
│   └── CLI.swift            # myna ask / agent / models / tool / tools
├── Resources/               # Info.plist, entitlements
├── docs/SIGNING.md          # Developer ID signing and notarization
├── docs/MCP.md              # MCP server configuration and usage
├── scripts/mcp-selftest.sh  # end-to-end MCP self-check
├── .github/workflows/       # ci.yml, upstream.yml, release.yml
├── config.example.json
├── build.sh                 # build + sign into ~/Applications
├── release.sh               # sign + notarize + package into dist/
├── dist/                    # build/release artifacts (gitignored)
└── LICENSE
```

### Runtime dependencies

The `PiKit` product is pulled from the published package
`https://github.com/quyansiyuanwang/pi-kit-swift.git` (pinned to `0.1.7` in
`Package.swift`); it in turn depends on `pi-ai-swift` and `pi-agent-swift`.
Everything is compiled into the `Myna` executable, so the built app is
self-contained. It spawns no Node process unless you configure an MCP server
that uses one ([docs/MCP.md](docs/MCP.md)).

## License

MIT
