# Project context — macos-ai-assistant (AiSiri)

- GitHub: https://github.com/quyansiyuanwang/macos-ai-assistant
- Product: `AiSiri` — a native macOS menu-bar assistant (SwiftPM only, no Xcode project).
- **Owner username: `quyansiyuanwang`.** Use it in every URL, badge, and
  `Package.swift` example. Never write `<owner>` or any other placeholder.
- Runtime: talks directly to the LLM (DeepSeek, OpenAI-compatible) via the
  `PiKit` product from `pi-kit-swift`. **Zero Node.js at runtime.**
- `agent_runtime` modes: `auto` / `package` / `builtin`.
- Swift 6 strict concurrency, zero warnings; build with
  `swift build -Xswiftc -warnings-as-errors`.
- Build/bundle with `./build.sh`; CLI symlink at `~/.local/bin/aisiri`.
- Docs: professional/technical tone, no emoji, no colloquialisms.
