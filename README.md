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
- Voice input via the Speech framework, speech output via AVSpeechSynthesizer
- Global hotkey (default `Option+Space`) to open the window and start listening
- 25+ local tools for controlling macOS
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
package (pinned to `0.1.2`), which re-exports `PiAI` and `PiAgentCore`. Node.js
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

Each conversation stores its own transcript. Switching rebuilds the agent context for
both runtimes — the Swift-package runtime restores it through `Agent.setTranscript`.
Conversations are persisted to `~/.config/myna/conversations.json`.

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

## Configuration

Open **Settings** from the menu bar context menu, the gear button in the window, or `Cmd+,`.
Changes are saved immediately to `~/.config/myna/config.json` (mode `0600`).

### Settings reference

The settings window uses a sidebar with the following sections:

| Section | Options |
|---|---|
| Appearance | Theme (system/light/dark), accent color, font size, density (compact/comfortable), bubble corner radius, avatars, timestamps, Markdown rendering, window opacity, default window size |
| Model | API protocol, API base URL, API key, model, connection test; agent runtime; temperature, top-p, frequency penalty, presence penalty, max tokens, retry count; system prompt |
| Voice | Speak replies, speak tool results, language, voice, rate, volume, pitch, preview; silence timeout, no-speech timeout, auto-send on silence, listen cue |
| Chat | Continuous mode, show tool calls, auto-scroll, clear on close, send-on-Enter, retained history turns |
| Behavior | Global hotkey (record any combination or pick a preset), menu bar icon, always-on-top, launch at login, show in Dock, open config file, restore defaults |
| Tools | Search, enable/disable all, per-tool toggles with danger flags |

### Config file fields

| Key | Type | Default | Description |
|---|---|---|---|
| `base_url` | string | `https://api.deepseek.com` | API base URL |
| `api` | string | `openai-completions` | API protocol: `openai-completions`, `openai-responses`, `anthropic-messages`, `google-generative-ai` |
| `api_key` | string | `""` | Provider API key |
| `model` | string | `deepseek-flash` | Model identifier (free-form) |
| `max_tokens` | int | `8192` | Maximum output tokens |
| `temperature` | double | `0.7` | Sampling temperature |
| `top_p` | double | `1.0` | Nucleus sampling |
| `frequency_penalty` | double | `0.0` | Frequency penalty |
| `presence_penalty` | double | `0.0` | Presence penalty |
| `max_retries` | int | `2` | Retry attempts on network errors and 429/5xx (both runtimes) |
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

### Environment variables

Environment variables override the config file:

| Variable | Overrides |
|---|---|
| `DEEPSEEK_API_KEY` | `api_key` |
| `MYNA_BASE_URL` | `base_url` |
| `MYNA_MODEL` | `model` |

## Command-line interface

```bash
myna ask "打开计算器，把音量调到30"     # built-in runtime
myna agent "现在几点？"                 # Swift-package agent runtime (PiKit)
myna tool get_datetime                  # run a single tool
myna tool open_app '{"name":"计算器"}'
myna tools                              # list all tools
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
│   ├── AIClient.swift       # built-in (fallback) streaming client and tool-call loop
│   ├── PackageRuntime.swift # Swift-package runtime (PiKit.AgentKit + AgentConfiguration)
│   ├── Tools.swift          # local tool implementations + PiKit.FunctionTool adapter
│   ├── Speech.swift         # speech recognition (silence detection) and synthesis
│   ├── HotKey.swift         # global hotkeys: recorder, double-tap, push-to-talk
│   └── CLI.swift            # myna ask / agent / tool / tools
├── Resources/               # Info.plist, entitlements
├── docs/SIGNING.md          # Developer ID signing and notarization
├── .github/workflows/       # ci.yml, upstream.yml, release.yml
├── config.example.json
├── build.sh                 # build + sign into ~/Applications
├── release.sh               # sign + notarize + package into dist/
├── dist/                    # build/release artifacts (gitignored)
└── LICENSE
```

### Runtime dependencies

The `PiKit` product is pulled from the published package
`https://github.com/quyansiyuanwang/pi-kit-swift.git` (pinned to `0.1.2` in
`Package.swift`); it in turn depends on `pi-ai-swift` and `pi-agent-swift`.
Everything is compiled into the `Myna` executable, so the built app is
self-contained and spawns no Node process.

## License

MIT
