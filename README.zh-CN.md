# Myna

[English](README.md) | 简体中文

[![CI](https://github.com/quyansiyuanwang/myna/actions/workflows/ci.yml/badge.svg)](https://github.com/quyansiyuanwang/myna/actions/workflows/ci.yml)

原生 macOS 菜单栏 AI 助手。直接与大模型对话（语音或文字），并通过工具操作本机：应用控制、媒体、提醒、日历、文件读写、Shell 命令、Git 等。

纯 Swift 实现，仅需 Swift 工具链即可构建，不依赖 Xcode 工程，运行期不依赖 Node.js。

## 上手与诊断

- 首次使用：未配置 API Key 时，聊天面板会直接显示配置引导卡片（而不是等发消息后报错）
- 后台会话完成通知：其它会话在后台跑完时发系统通知，点击切回该会话（可在「设置 → 行为」关闭）
- Token 消费统计：每轮运行按服务端返回的用量累加到会话，⌘K 会话条目与对话列表显示 ↑输入 ↓输出，「设置 → 诊断」显示全局合计
- ⌘K 支持跨对话全文搜索：输入 2 个以上字符即可在所有对话的消息正文里检索，选中后跳转并高亮那条消息
- 多社区仓库：市场来源可配置（任意提供 `registry.json` 的目录，含本地 `file://`），按顺序决定优先级、同 id 去重、安装时回到条目自身来源，单个来源失败不影响其它；`myna market-sources` 管理来源
- 卡死自愈：看门狗确认主线程卡死 8 秒后会自动带「安全模式」重启（关闭滚动观测/导航轨/悬停条、压缩渲染条数），界面顶部提示条一键恢复；安全模式不改动用户配置
- 卡死防护：超长消息（>3000 字）默认折叠、滚动状态写入收敛并带滞回（避免重排反馈环）、内置主线程看门狗把卡死现场写进 `~/.config/myna/stall.log`
- 性能开关：「设置 → 外观 → 性能」提供关闭阴影与动画、流式期纯文本渲染、渲染上限（长对话只渲染最近 N 条），并提供一键「性能模式」；实测 500 条消息下把一轮流式回答的 CPU 从 6.8s/8s 降到 3.2s/8s、内存从 221MB 降到 176MB
- 处理过程统一收起：思考与工具调用各收成一行摘要，点击整行展开（设置 → 对话 → 处理过程 可分别调整合并与自动收起）；消息内容始终完整显示
- 处理过程合并折叠：连续的思考 / 工具调用会自动并成一组，可展开查看每一步；对话完成后自动收起，只留最终回答（可在「设置 → 对话 → 处理过程」调整）
- 思考强度设为「关闭」时不再显示思考内容（推理模型仍可能内部生成，这里只是不展示）
- 打开面板即停在最新消息；向上翻阅时右下角出现「最新」按钮一键回到底部
- 消息区右侧的纵向导航轨：每条用户消息一个刻度，点击跳转，当前轮次高亮
- 「设置 → 外观 → 窗口」可用「用当前大小作为默认」把当前宽高存为默认值
- 对话分支：鼠标悬停在任意消息上（或右键）可「从这里分叉」，新对话保留该条及之前的上下文，原对话不变
- 「设置 → 诊断」集中展示麦克风 / 辅助功能权限状态，可一键申请或跳转系统设置，
  并列出配置文件、会话数、MCP 运行时（Node / uv）与常用目录
- 「设置 → 工具」的编程、网络搜索、网络代理、MCP 四个分区默认折叠，
  折叠行会显示当前状态摘要

## 网络能力

- **联网搜索**：支持 Tavily / Brave / Serper / 自定义接口，模型可用 `web_search` 检索、`fetch_url` 抓取正文
- **网络代理**：HTTP / HTTPS / SOCKS5，可带认证与绕过列表；模型请求、搜索与更新检查统一走代理
- **MCP 服务器**：设置内直接增删改，支持参数与环境变量，改完可即时重载

详见 [docs/zh/network.md](docs/zh/network.md)。

## 特性概览

- **四种接口协议**：`openai-completions`、`openai-responses`、`anthropic-messages`、`google-generative-ai`，配置中指明协议而非厂商
- **供应商与模型**：模型按供应商组织，每个供应商自带名称、协议、地址、Key 与模型列表；模型可手动录入或从端点**探测**，一键切换
- **逐模型思考强度**：每个模型声明自己支持的思考等级（关闭 / 极简 / 低 / 中 / 高 / 极高 / 最大），可在聊天输入栏的模型控件中直接切换（点击模型名在输入栏上方展开内联面板，展开供应商 / 模型列表后拖动滑块调整思考强度），预算协议自动按等级推导思考预算
- **会话模式**：计划模式只读调研并产出可执行计划，批准后继续；目标模式绑定目标并自动续跑（有轮数上限）；创造模式允许写文件、生成技能 / 插件 / 文档
- **上下文压缩**：接近阈值自动摘要旧轮次，也可手动压缩；保留最近轮数与工具结构，失败自动退化为截断，压缩前后 token 显示在对话里
- **附件**：输入栏或拖拽附加文件 / 文件夹；小文本内联，文件夹只生成浅层清单，图片交给 `view_image`
- **权限管理**：「设置 → 权限」按工具设置允许 / 询问 / 拒绝，危险工具默认询问；计划模式强制只读；系统 TCC 权限集中查看
- **配置方案**：保存**全部设置**的完整快照（不只是模型），一键切换，可导出 / 导入方案或完整配置
- **语音优先**：语音输入（静音自动结束）、语音朗读、连续对话；快捷键支持录入任意组合键、双击修饰键、长按说话
- **62 个本机工具**：应用/媒体/提醒/日历/剪贴板/系统信息，**文件读写编辑、目录与全文搜索、Git、Shell 命令**，**自我控制 / 自我扩展**，以及 **computer use（截屏、OCR、鼠标、键盘、窗口、图片）**
- **编程模式**：以**每个会话自己的工作目录**为根（未设置时回退应用默认），像 coding agent 一样读代码、改代码、跑构建与测试
- **子代理**：`run_subagent` / `run_subagents`，把自包含任务交给独立上下文的子代理（可并行）
- **后台与并行**：每个会话独立运行，切换会话或关闭面板都不中断；可配并行上限
- **技能与提示词模板**：本地 Markdown 资源，技能摘要注入系统提示词，模型按需读取
- **MCP**：接入任意 Model Context Protocol 服务器（stdio），工具以 `mcp__<服务器>__<工具>` 暴露
- **多源市场**：任意提供 `registry.json` 的来源（GitHub raw、镜像、本地目录），按顺序决定优先级；内置来源为 [myna-hub](https://github.com/quyansiyuanwang/myna-hub)
- **自我扩展**：Myna 可以在运行时为自己创建技能、本地插件与 MCP 服务器，下一次运行即生效；技能与插件会进入系统提示词
- **自我控制 API**：读写自身配置（校验 + 备份 + 恢复）、查看 / 申请权限、读取 / 导出 / 删除本地数据
- **computer use**：截屏、窗口列表、本地 OCR 读屏、鼠标移动 / 点击 / 拖拽 / 滚动、键盘按键与输入；视觉模型可直接看图片
- **消息操作与代码高亮**：消息支持复制 / 重发 / 编辑并重发（悬停操作条与右键菜单）；代码块按语言高亮并自带「复制」按钮
- **高度可定制**：外观主题、强调色、字号、密度、气泡、时间戳、Markdown、不透明度、面板尺寸、快捷键、显示筛选等

## 安装

### Homebrew（推荐）

```sh
brew install --cask quyansiyuanwang/tap/myna
```

安装到 `/Applications` 并自动剥除 quarantine 属性，无需 Gatekeeper 操作。

### 下载

从 [Releases](https://github.com/quyansiyuanwang/myna/releases) 下载 `Myna-v<版本>.zip` 或 `.dmg`，解压后：

```sh
xattr -dr com.apple.quarantine /Applications/Myna.app
```

应用为 ad-hoc 签名（公证需要付费 Developer ID 证书），首次启动可右键选择「打开」。

本地构建可用 `./scripts/setup-local-signing.sh` 创建稳定的自签名证书，再由 `./build.sh` 自动使用。它的 designated requirement 是「bundle id + 证书叶哈希」，不随每次构建变化，因此屏幕录制 / 辅助功能授权能在重新编译后保留；该证书只用于本机，不参与发布包。

### 从源码构建

```sh
git clone https://github.com/quyansiyuanwang/myna.git
cd myna
./build.sh
```

## 环境要求

- macOS 13 或更高（开发环境为 macOS 15）
- Swift 工具链：`xcode-select --install`
- 一个 OpenAI 兼容（或其他受支持协议）端点的 API Key

## 构建与安装

`./build.sh` 会编译 Release 并产出：

| 路径 | 说明 |
|---|---|
| `~/Applications/Myna.app` | 菜单栏应用 |
| `~/.local/bin/myna` | 命令行（指向应用内二进制的软链） |
| `~/.config/myna/config.json` | 配置文件（权限 0600） |

## 使用

点击菜单栏图标或按全局快捷键即可打开面板。

### 窗口模式

默认使用**下拉面板**：锚定菜单栏图标、向下展开，点击外部或失去焦点自动关闭，按 Esc 也可关闭。面板右下角可**拖拽调整大小**。

在「设置 → 行为」中关闭「下拉面板模式」即切换为普通窗口（可移动、可缩放、可最小化）。

普通窗口建议同时打开「设置 → 行为 → 在 Dock 中显示」：菜单栏应用默认不进入 `Command+Tab`，打开 Dock 图标后即可切换；窗口最小化或被关闭后，点击 Dock 图标、按 `Command+0` 或全局快捷键都会把它带回来。应用会记住上次的窗口可见状态与所在会话，重启 / 安全模式恢复 / 更新后回到同一段对话。

### 语音交互

1. 按快捷键（默认 `⌥Space`）或点击麦克风按钮开始录音
2. 实时转写显示在输入框内，不覆盖已输入的文字
3. 静音约 1.5 秒自动结束；也可再按一次快捷键或点击麦克风手动结束
4. 快捷键结束时默认**直接发送**（`hotkey_auto_send`）；麦克风按钮结束则只填入输入框，便于修改
5. 回车发送；发送时立即释放麦克风，回答流式输出并朗读

### 快捷键

在「设置 → 行为 → 快捷键」中：

- **触发方式**：组合键（可**录入**任意组合）或**双击修饰键**（如连按两次 ⌥，需辅助功能权限）
- **按下行为**：按下切换，或**按住说话**（松开即结束并发送）
- **附加热键**：只打开窗口、清空对话
- 非法组合（如无修饰键的单键）不会被注册；与其他应用冲突会给出提示

### 会话

顶栏「列表」按钮打开会话面板：

- 切换、新建、重命名、删除会话
- **每个会话可单独设置工作目录**：右键→「工作目录…」，或在聊天顶栏点击文件夹胶囊；「清除工作目录」恢复为应用默认
- **全文搜索**：跨全部会话检索，命中显示片段，点击跳转到该条消息并高亮
- 导出 / 导入 JSON（含会话自己的工作目录）
- 运行中的会话显示转圈与「停止」按钮

### 后台与并行

每个会话拥有独立的运行上下文：

- 切换会话或关闭面板**不会中断**后台任务
- 多个会话可同时运行，上限由 `max_parallel_runs` 控制（超出时取消最旧的并在该会话留下提示）
- 关闭 `background_runs` 可恢复旧行为（切换即取消）

### 消息显示

思考与工具调用以**可折叠区块**呈现（点击标题展开/收起）：

| 设置 | 默认 | 说明 |
|---|---|---|
| `show_thinking` | true | 显示思考过程 |
| `show_tool_calls` | true | 显示工具调用 |
| `show_tool_results` | true | 显示工具结果 |
| `show_errors` | true | 显示错误消息 |
| `collapse_thinking` / `collapse_tools` | true | 区块默认收起 |

以上均在渲染时生效，切换开关会立即影响**已有**消息。顶栏「筛选」按钮可按关键词过滤当前会话。

### 消息操作与代码高亮

每条用户 / 助手消息在悬停时会显现一条紧凑的操作条（鼠标移入消息行即出现），右键菜单提供同样的操作：

- **复制**：复制整条消息文本；图标会短暂变为勾号作为反馈
- **重发**：用户消息按原文重新发送；助手消息则回退到其前一条用户消息后重新生成。运行中（`model.busy`）时禁用
- **编辑并重发**：仅用户消息。气泡就地切换为内联编辑器，⌘↩ 保存并重发，Esc 取消；保存时会截断该消息之后的全部轮次，并用编辑后的文本重新发送

截断会同时作用于会话的**运行上下文**（而不只是界面镜像）：内置运行时用截断后的气泡重建消息历史，Swift 包运行时通过 `Agent.setTranscript` 重建 transcript，因此模型不会再记得被删除的轮次。编辑对后台会话同样生效。

助手回复中的围栏代码块会解析语言信息串并按语言高亮（Swift、JavaScript / TypeScript、Python、JSON、Shell、Go、Rust、Java、C / C++ / Objective-C、HTML、CSS、SQL、YAML、Markdown、Ruby、PHP、Kotlin 等）。每个代码块顶部有语言标签与「复制」按钮（复制原始代码，不含语言标签，点击后显示「已复制」）；代码正文可选择，长行会自动换行，空代码块也不会撑破布局。高亮在流式输出时实时生效，明暗外观各有一套配色。

### 提示词模板与技能

```
~/.config/myna/prompts/*.md            提示词模板
~/.config/myna/skills/<id>/SKILL.md    技能
```

- 提示词模板出现在输入栏的模板菜单中，点击插入输入框（不自动发送）
- 技能支持 YAML frontmatter，`name` / `description` 注入系统提示词，模型用 `read_skill` 读取全文
- 同时会扫描 `~/.pi/agent/skills/`，pi 的技能可直接使用

### 市场

「设置 → 市场」可同时接入多个来源：只要目录下提供 `registry.json`（含 `skills` / `mcps` / `plugins`）即可，支持 `owner/repo[@branch]`、`https://…` 与本地 `file://`。来源可增删、启停，列表顺序即优先级；同 id 条目由靠前的来源胜出，安装文件时回到条目自己的来源。单个来源加载失败只在该来源行标注，不影响其他来源。

内置来源是 [myna-hub](https://github.com/quyansiyuanwang/myna-hub)。下方分技能、MCP、插件与**本地插件**四类；本地插件是 Myna 自己创建的 JSON 清单（`~/.config/myna/plugins/<id>.json`），可把技能与 MCP 组合起来并附加一段注入系统提示词的 `instructions`。

命令行同样可用：

```sh
myna market-sources list
myna market-sources add team https://example.org/hub
myna market-sources add local ~/hubs/team
myna market-install skill daily-report
myna market-install mcp memory
myna market-install plugin morning-routine
```

### 自我扩展与自我控制

工具：`myna_settings`、`myna_permissions`、`myna_data`、`skill_write`、`skill_delete`、`mcp_manage`、`plugin_manage`。也可以从命令行调用同一套 API：

```sh
myna api settings.get
myna api settings.set '{"key":"temperature","value":0.5}'
myna api permissions.status
myna api data.list
myna api skill.write '{"id":"daily","name":"日报","description":"...","body":"..."}'
myna api plugin.create '{"id":"pack","name":"包","instructions":"...","skills":["daily"]}'
myna api mcp.add '{"id":"fs","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"]}'
```

配置写入会先校验（把合并后的 JSON 解码回 `AppSettings`，再编码比对目标键），不合法就拒绝并保留原文件；每次写入前备份到 `~/.config/myna/backups/`。技能 / 插件 / MCP / 配置变更会广播给界面，下一次运行重建 Agent（保留对话上下文）。

### 电脑操作与视觉

「设置 → 工具 → 电脑操作」可分别开关读屏、鼠标键盘与 OCR，并显示系统权限状态、提供申请与跳转按钮：

- `screenshot`：主屏 / 指定显示器 / 指定窗口 / 区域截图，返回路径、像素尺寸、屏幕坐标与前台应用；模型声明视觉时默认随结果附上图片（`attach=false` 可关闭）
- `read_screen`：截图 + 本地 Vision OCR，返回归一化文字坐标，纯文本模型也能「读屏」
- `list_windows` / `activate_app`：窗口清单与应用激活
- `mouse_move` / `mouse_click` / `mouse_drag` / `scroll` / `key_press` / `type_text` / `wait`：CoreGraphics 事件
- `view_image`：读取本地图片；只有模型在「模型 → 编辑 → 支持图片输入（视觉）」中声明后，才会把图片块发给模型，否则返回路径并提示改用 `read_screen`

截屏需要「屏幕录制」权限，鼠标键盘需要「辅助功能」权限；权限由 macOS 管理，授权后需重启 Myna。

### 编程模式

开启「设置 → 工具 → 编程模式」后：

- 系统提示词追加工程化指令（先看再改、小步精确修改、改完跑构建/测试、如实汇报改动）
- 所有相对路径以**当前会话的工作目录**为根；未单独设置时回退到「设置 → 工具 → 默认工作目录」（`working_directory`），仍为空则使用用户主目录
- 可在会话列表右键「工作目录…」或聊天顶栏的文件夹胶囊单独设置；「清除工作目录」恢复默认
- 可用工具：`read_file`、`write_file`、`edit_file`、`list_dir`、`find_files`、`search_text`、`make_dir`、`move_path`、`delete_path`、`git_status`、`git_diff`、`git_log`、`git_commit`、`run_command`

危险工具（`delete_path`、`git_commit`、`run_command`、`shell_command`、`run_applescript`、`myna_settings`、`myna_data`、`skill_delete`、`plugin_manage`、`mcp_manage`，以及鼠标 / 键盘控制工具）在设置中标记为「危险」；开启 `confirm_dangerous_tools` 后这些工具会被硬拦截，要求模型先征得确认。

### 子代理

`run_subagent` 把自包含任务交给独立上下文的子代理，返回其最终结果；`run_subagents` 并行运行多个子代理。适合较长、多步、且不希望污染当前对话的任务。子代理可跟随主模型，也可指定单独的供应商与模型；超时与轮数支持「自定义 / 无限制」（无限制仍有内部安全上限），默认禁止递归派生子代理（可在高级设置中开启），并受并行上限约束。

## 配置

打开「设置」（菜单栏右键、窗口齿轮按钮或 `⌘,`），改动立即保存到 `~/.config/myna/config.json`（0600）。

### 设置界面分区

| 分区 | 内容 |
|---|---|
| 外观 | 主题（跟随系统/浅色/深色）、强调色、字号、密度、气泡圆角、头像、时间戳、Markdown、不透明度、窗口尺寸 |
| 模型 | 供应商与模型的整合树（点行体切换当前供应商；内联编辑名称 / 协议 / 地址 / Key，手动录入或**探测模型**后多选添加，点模型行即切换，可编辑 / 复制 / 删除）、连接测试，以及默认收起的「更多」高级分区（生成参数、运行时、高级、子agent、系统提示词）。探测不会直接写入，而是弹出可筛选、可全选 / 全不选的多选列表，确认后只合并所选模型 |
| 配置 | 配置方案（保存 / 应用 / 重命名 / 删除 / 导出 / 导入）、完整配置导入导出、打开配置文件、恢复默认设置 |
| 语音 | 朗读、语言、音色、语速、音量、音调、试听；静音超时、未说话超时、自动发送、提示音 |
| 对话 | 连续对话、自动滚动、关闭清空、后台运行、并行上限、显示内容、输入方式 |
| 行为 | 快捷键、菜单栏图标与大小、面板模式与可缩放、置顶、开机自启、Dock 图标、配置文件 |
| 工具 | 默认工作目录、编程模式、子代理参数、电脑操作（读屏 / 鼠标键盘 / OCR / 权限状态）、搜索、MCP、批量启停、逐工具开关（含危险标记） |
| 市场 | 多来源管理、技能 / MCP / 插件浏览与安装、本地插件开关与删除 |
| 关于 | 版本与链接 |

完整的配置项清单见 [docs/zh/config.md](docs/zh/config.md)。

### 环境变量

环境变量会覆盖配置文件，且**不写回**配置文件：

| 变量 | 覆盖 |
|---|---|
| `DEEPSEEK_API_KEY` | `api_key` |
| `MYNA_BASE_URL` | `base_url` |
| `MYNA_MODEL` | `model` |
| `MYNA_HUB_BASE` | 市场仓库地址（插入为最高优先级来源） |
| `MYNA_MCP_CONFIG` | MCP 配置文件路径 |
| `MYNA_CONFIG` | 配置文件路径；技能、插件、方案、备份与截图都跟随其父目录 |
| `MYNA_CONVERSATIONS` | 会话文件路径 |
| `MYNA_STALL_LOG` / `MYNA_SAFE_MODE_FILE` | 卡死快照 / 安全模式标记路径 |

## 命令行

```sh
myna ask "打开计算器，把音量调到30"     # 内置运行时
myna agent "现在几点？"                 # Swift 包运行时（PiAI + PiAgentCore）
myna tools                              # 列出全部工具（含 MCP）
myna tool get_datetime                  # 直接执行某个工具
myna tool open_app '{"name":"计算器"}'
myna models                             # 探测模型并并入当前供应商
myna profiles list                      # 列出配置方案（隐藏命令）
myna market-sources list                # 列出市场来源（隐藏命令）
myna market-install skill daily-report  # 从任一启用来源安装
myna api settings.get                   # 自我控制 API
myna self-check                         # 隔离目录内验证自我控制闭环
myna computer-check                     # 验证坐标 / 按键 / 截图 / 图片编码（不注入真实输入）
```

## Agent 运行时

`agent_runtime` 有三个取值：

| 值 | 说明 |
|---|---|
| `auto`（默认） | 优先 Swift 包运行时，不可用时回退内置实现 |
| `package` | 直接链接 [pi-kit-swift](https://github.com/quyansiyuanwang/pi-kit-swift)（其内部为 PiAI + PiAgentCore） |
| `builtin` | 内置手写实现，仅支持 `openai-completions` |

Swift 包运行时运行期零 Node、零额外进程；采样参数通过 `LiveSamplingProvider` 在每次请求时注入，调整温度 / Top-P 等**不会重建 Agent、不会丢失上下文**。

## MCP 服务器

在 `~/.config/myna/mcp.json` 中登记（首次运行会生成模板与说明）：

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"],
      "env": {}
    }
  }
}
```

工具以 `mcp__filesystem__read_text_file` 形式暴露，并尊重 `disabled_tools`。详见 [docs/MCP.md](docs/MCP.md)。

## 权限

在「系统设置 → 隐私与安全性」中按需授权：

| 权限 | 用途 |
|---|---|
| 麦克风 / 语音识别 | 语音输入 |
| 辅助功能 | 双击修饰键触发、模拟键盘输入 |
| 自动化（Apple Events） | 通过 AppleScript 控制音乐、日历、提醒等 |
| 屏幕录制 | 部分工具需要 |

授权后若仍显示未授权，先确认 Myna 不是从终端 / 自动化工具启动的：TCC 会把授权归因到启动它的 responsible process。请从 Dock / Finder / 登录项启动。旧的授权条目可清除后重新授权：

```sh
tccutil reset ScreenCapture com.local.myna
tccutil reset Accessibility com.local.myna
```

## 架构

```
myna/
├── Sources/Myna/
│   ├── main.swift              # 入口（GUI / CLI）
│   ├── AppDelegate.swift       # 菜单栏、窗口/面板、主菜单、热键、登录项
│   ├── ChatView.swift          # 聊天界面与 ChatModel
│   ├── ChatSession.swift       # 每会话运行上下文
│   ├── ConversationListView.swift
│   ├── PromptListView.swift
│   ├── SettingsView.swift      # 设置界面（侧边栏）
│   ├── Config.swift            # AppSettings / SettingsStore
│   ├── Providers.swift         # 供应商与模型的数据模型、选择与迁移
│   ├── Profiles.swift          # 完整配置方案（profiles/<名称>.json）
│   ├── ModelDiscovery.swift    # 端点模型探测
│   ├── Conversations.swift     # 会话模型与存储、全文搜索
│   ├── Marketplace.swift       # 多来源市场与安装
│   ├── SelfControl.swift       # 自我控制 API：配置 / 权限 / 数据 / 技能 / 插件 / MCP
│   ├── ComputerUse.swift       # 截屏 / OCR / 窗口 / 鼠标 / 键盘 / 图片块
│   ├── Theme.swift             # 外观主题与代码高亮调色板
│   ├── SyntaxHighlight.swift   # 代码高亮令牌器（无第三方依赖）
│   ├── Models.swift            # 接口类型
│   ├── AIClient.swift          # 内置运行时
│   ├── PackageRuntime.swift    # Swift 包运行时装配
│   ├── Tools.swift             # 本机工具声明与分发
│   ├── CodingTools.swift       # 文件 / 搜索 / Git / 命令工具
│   ├── SubAgent.swift          # 子代理
│   ├── MCPClient.swift         # MCP JSON-RPC stdio 客户端
│   ├── MCPManager.swift        # MCP 生命周期与工具暴露
│   ├── Resources.swift         # 提示词模板与技能
│   ├── Speech.swift            # 语音识别与合成
│   ├── HotKey.swift            # 全局热键、录入、双击、长按
│   └── CLI.swift               # 命令行
├── Resources/                  # Info.plist、entitlements、图标
├── docs/                       # 文档（中文见 docs/zh）
├── scripts/                    # 打包与 DMG
├── build.sh / release.sh
└── LICENSE
```

### 运行期依赖

`PiKit` 产品来自已发布包 [pi-kit-swift](https://github.com/quyansiyuanwang/pi-kit-swift)，它再依赖 `pi-ai-swift` 与 `pi-agent-swift`。三者全部编译进 `Myna` 可执行文件，构建与运行都不需要 Node.js。

## 文档

- [快速开始](docs/zh/getting-started.md)
- [模型与推理](docs/zh/models.md)
- [聊天与消息操作](docs/zh/chat.md)
- [语音与快捷键](docs/zh/voice.md)
- [技能与 MCP](docs/zh/skills-mcp.md)
- [编程模式](docs/zh/coding.md)
- [后台与并行](docs/zh/background.md)
- [配置项全表](docs/zh/config.md)
- [常见问题](docs/zh/faq.md)
- [签名与公证](docs/SIGNING.md)（英文）

## 许可

MIT
