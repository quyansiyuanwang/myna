# 常见问题

[返回主文档](../../README.zh-CN.md) · [配置项全表](config.md)

## 安装与启动

**提示「无法打开，因为无法验证开发者」**
应用为 ad-hoc 签名、未公证（公证需要付费 Developer ID 证书）。执行：

```sh
xattr -dr com.apple.quarantine /Applications/Myna.app
```

或右键点击应用选择「打开」。用 Homebrew 安装的 cask 会自动处理。

**菜单栏没有图标**
确认应用在运行（`pgrep -fl Myna`）。若菜单栏图标被系统隐藏，检查「系统设置 → 控制中心 → 菜单栏」中的项目数量是否过多。

**图标太大或太小**
「设置 → 行为 → 菜单栏图标 → 图标大小」可调 11–22pt。

## 权限

**每次重新编译 / 更新后都要重新授权**
ad-hoc 签名的 designated requirement 是 cdhash，每次构建都会变化，TCC 会视为新应用。本地开发可用稳定自签名证书解决：

```sh
./scripts/setup-local-signing.sh   # 生成 Myna Local Code Signing
./build.sh                         # 自动使用该证书签名
```

证书的 requirement 是 `identifier "com.local.myna" and certificate leaf = H"..."`，不随二进制变化；首次授权后，后续重新编译仍保留。用 Homebrew 更新后（发布包是 ad-hoc），可对已安装的 App 重新签名，无需重新构建：

```sh
./scripts/resign-local.sh ~/Applications/Myna.app
```该证书不受 Gatekeeper 信任，只用于本机；发布包仍是 ad-hoc，因为私钥不能进仓库。若要免 Gatekeeper 提示并长期分发，仍需要 Developer ID 证书与公证，见 [docs/SIGNING.md](../SIGNING.md)。

**系统设置里已经勾选，但 Myna 仍显示未授权**
先确认 Myna 不是从终端 / 自动化工具（Terminal、iTerm、DeepSeek Harness 等）启动的。TCC 会把子进程的授权归因到 **responsible process**，即启动它的终端，而不是 Myna。请在「设置 → 行为」确认「开机自启」已开启（LaunchAgent 直接执行 App 二进制），或从 Dock / Finder 启动；不要用 `open -a` 从终端拉起后再授权。

旧的授权条目可能还指向旧 cdhash。清除后重新授权：

```sh
tccutil reset ScreenCapture com.local.myna
tccutil reset Accessibility com.local.myna
```

重启 Myna，打开「设置 → 诊断」点「申请」，在系统弹窗中授权；屏幕录制授权后点「重启 Myna 以应用权限」。

**语音输入没反应**
检查「麦克风」与「语音识别」权限。若曾点过「不允许」，需在系统设置中手动改回。

**双击修饰键无效**
需要「辅助功能」权限；设置界面会给出提示与跳转按钮。

## 模型

**提示 `invalid x-api-key` 或 401**
Key 与端点不匹配。注意接口类型要选对（例如 Anthropic 的端点配 `anthropic-messages` 协议）。

**「探测模型」返回 404**
该端点没有实现 `/models`。可在供应商的模型列表中直接手动输入模型 id。

**改温度后对话上下文丢失？**
不会。采样参数在每次请求时注入，调整它们不会重建 Agent。

**长任务跑到一半停了**
把「工具执行最大轮数」设为 0，或开启它下方的「无限」。两个选项都在「设置 → 模型 → 更多 → 高级」里。

## 面板与窗口

**面板不显示**
默认是下拉面板模式，点击菜单栏图标才会出现。若开启过「在 Dock 中显示图标」，也可从 Dock 激活。

**面板无法调整大小**
确认「允许拖拽调整面板大小」已开启，然后拖动面板右下角的箭头。

**面板透明度设置没效果**
透明度作用于面板窗口本身，值越低越透明（最低 0.7）。若完全无变化，确认当前处于面板模式。

**打开设置后设置窗口被挡住**
打开设置时会自动收起面板，不应再出现遮挡。

## MCP

**服务器启动失败**
查看 stderr 中的 `[mcp:<服务器>]` 前缀输出。常见原因：命令不存在（如未安装 Node 导致 `npx` 不可用）、首次运行时 `npx` 下载超时。

**工具没出现在列表里**
MCP 服务器异步启动，稍等片刻；命令行 `myna tools` 会等待启动完成。

## 技能与市场

**技能没有生效**
确认路径为 `~/.config/myna/skills/<id>/SKILL.md`，且 frontmatter 有 `name` 与 `description`。用 `myna tool list_skills` 检查。

**市场安装失败**
网络受限时可用镜像：设置 `MYNA_HUB_BASE` 指向镜像地址。

## 配置

**配置文件在哪**
`~/.config/myna/config.json`（0600）。改动即时保存，拖动滑块时做了防抖，退出前会强制落盘。

**如何恢复默认**
「设置 → 行为 → 恢复默认设置」。建议先备份配置文件。

## 其他

**运行期是否依赖 Node.js**
不依赖。Agent 运行时由 Swift 包 [pi-kit-swift](https://github.com/quyansiyuanwang/pi-kit-swift) 提供，全部编译进可执行文件。只有你配置的 MCP 服务器若用 `npx` 启动，才需要 Node。

**命令行在哪**
`~/.local/bin/myna`（指向应用内二进制）。运行 `myna help` 查看用法。
