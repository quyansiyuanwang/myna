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
