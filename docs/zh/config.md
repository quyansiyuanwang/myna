# 配置项全表

配置文件位于 `~/.config/myna/config.json`（权限 0600），由「设置」界面即时写入。所有字段缺失时都会回退到默认值，因此旧配置始终可用。

[返回主文档](../../README.zh-CN.md)

## 模型

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `base_url` | string | `https://api.deepseek.com` | 接口地址 |
| `api_key` | string | `""` | API Key |
| `model` | string | `deepseek-flash` | 模型标识（自由填写，可用 `myna models` 探测） |
| `api` | string | `openai-completions` | 接口协议：`openai-completions` / `openai-responses` / `anthropic-messages` / `google-generative-ai` |
| `reasoning_effort` | string | `""` | 当前模型选中的思考等级（规范等级之一）；空 / `off` 表示不发送对应字段 |
| `thinking_budget` | int | `0` | 当前模型解析后的思考预算（tokens），0 = 不发送；预算协议由等级推导 |
| `recent_models` | string[] | `[]` | 最近使用过的模型 |
| `providers` | object[] | `[]` | 供应商列表：每个供应商自带协议 / 地址 / Key 与模型列表，见下 |
| `active_provider_id` | string \| null | `null` | 当前选中的供应商 id |
| `active_model_id` | string \| null | `null` | 当前选中的模型 id |
| `model_list` | string[] | `[]` | **旧版字段（仅迁移）**，加载后会被转换成模型并写回空数组 |
| `model_profiles` | object[] | `[]` | **旧版字段（仅迁移）**，加载后会被转换成供应商并写回空数组 |
| `max_tokens` | int | `8192` | 单次输出上限 |
| `temperature` | double | `0.7` | 温度 |
| `top_p` | double | `1.0` | 核采样 |
| `frequency_penalty` | double | `0.0` | 频率惩罚 |
| `presence_penalty` | double | `0.0` | 存在惩罚 |
| `max_retries` | int | `2` | 网络错误与 429/5xx 的重试次数（两个运行时都生效） |
| `max_tool_rounds` | int | `8` | 每次提问的工具执行轮数上限；**`0` 表示不限制** |
| `unlimited_tool_rounds` | bool | `false` | 勾选后忽略 `max_tool_rounds`，始终不限制 |
| `supports_vision` | bool | `false` | 当前模型是否接受图片输入；在「模型 → 编辑」中按模型设置，并镜像到该扁平字段。关闭时 `view_image` 只返回路径与尺寸 |
| `system_prompt` | string | 内置（简洁版） | 系统提示词；旧配置里已保存的内容不会被自动替换 |

### 供应商与模型字段

`providers` 数组中的每一项（供应商）：

| 键 | 类型 | 说明 |
|---|---|---|
| `id` | string | UUID |
| `name` | string | 显示名称，例如「DeepSeek」 |
| `api` | string | 接口协议，同顶层 `api` |
| `base_url` / `api_key` | string | 该供应商的地址与 Key |
| `selected_model_id` | string \| null | 该供应商上次使用的模型 id（切换回来时记忆位置） |
| `models` | object[] | 属于该供应商的模型，见下 |

`models` 数组中的每一项（模型）：

| 键 | 类型 | 说明 |
|---|---|---|
| `id` | string | UUID |
| `name` | string | 发送给接口的模型 id |
| `display_name` | string | 显示名，留空则显示 `name` |
| `reasoning_effort` | string | 该模型选中的思考等级；空 / `off` = 关闭 |
| `thinking_levels` | string[] | 该模型声明支持的思考等级（规范顺序、去重，未知等级会被丢弃） |
| `thinking_budget` | int | 仅 Anthropic / Gemini：`> 0` 时覆盖由等级推导的预算，`0` = 由等级推导 |
| `max_tokens` | int | 单次输出上限，**0 = 沿用顶层设置** |
| `temperature` | double | 温度，**< 0 = 沿用顶层设置** |
| `context_window` | int | 上下文窗口（0 = 未知） |
| `discovered` | bool | 是否由端点探测得到 |
| `supports_vision` | bool | 该模型是否接受图片输入（视觉） |

顶层的扁平字段是**当前生效配置**；选择供应商 / 模型时会把其值写入顶层字段，直接编辑顶层字段同样生效，且不会回写供应商。

#### 思考等级

规范等级共七级，顺序固定：`off` → `minimal` → `low` → `medium` → `high` → `xhigh` → `max`。新建模型时按协议填入默认等级（`openai-responses` 为全部七级，`openai-completions` 到 `high`，Anthropic / Gemini 到 `max`）。预算协议下，预算优先取 `thinking_budget`（`> 0`），否则由等级推导：`off`=0、`minimal`=1024、`low`=2048、`medium`=4096、`high`=8192、`xhigh`=16384、`max`=32768。

加载旧配置时会补全 `thinking_levels`：非空 `reasoning_effort` 若不在列表中会被追回；`thinking_levels` 为空但 `thinking_budget > 0` 时按协议默认值播种。全新模型（手动添加 / 探测）直接写入协议默认等级。

### 旧配置迁移

加载时若 `providers` 为空，会把 `model_profiles` 按「`base_url` + `api`」分组转换成供应商（每组的第一个档案名成为供应商名，后续档案名成为对应模型的 `display_name`），再把 `model_list` 追加到与当前 `base_url` / `api` 匹配的供应商，最后保证存在至少一个供应商且 `active_provider_id` / `active_model_id` 指向与扁平字段一致的条目。迁移完成后 `model_profiles` / `model_list` 写回空数组（仍保留一个版本的解码兼容）。

## 配置方案

配置方案是**完整配置快照**（不只是模型）：每个方案对应 `~/.config/myna/profiles/<名称>.json`，内容与 `config.json` 同构（`model_profiles` / `model_list` 写为空数组）。应用方案会整体替换当前设置，因此外观、语音、对话、行为、工具等都会一并恢复。

| 操作 | 说明 |
|---|---|
| 保存当前为新方案 | 把当前全部设置写入方案文件 |
| 应用 | 用方案文件整体替换当前设置 |
| 重命名 / 删除 | 重命名或删除方案文件 |
| 导出 / 导入方案 | 把方案文件复制到指定位置 / 从文件导入 |
| 导出 / 导入完整配置 | 直接读写 `config.json` 的内容 |

在「设置 → 配置」中操作。

## 子代理

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `subagent_timeout_seconds` | int | `300` | 单个子代理超时 |
| `subagent_max_rounds` | int | `16` | 子代理工具轮数上限 |
| `subagent_max_parallel` | int | `3` | `run_subagents` 的并行上限 |
| `subagent_provider_id` | string \| null | `null` | 子代理使用的供应商 id；为空跟随主模型 |
| `subagent_model_id` | string \| null | `null` | 子代理使用的模型 id；为空跟随主模型 |
| `subagent_unlimited_rounds` | bool | `false` | 勾选后忽略 `subagent_max_rounds`，使用内部安全上限 |
| `subagent_unlimited_timeout` | bool | `false` | 勾选后忽略 `subagent_timeout_seconds`，使用内部安全上限 |
| `subagent_allow_recursion` | bool | `false` | 允许子代理再派生子代理（默认关闭，防止递归与费用失控） |

子代理的「跟随主模型 / 指定模型」「自定义 / 无限制」与递归开关都在「设置 → 模型 → 更多 → 子agent」中调整；指定模型与跟随主模型都读写上面的四个键。

## 编程

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `working_directory` | string | `""` | 新建对话的默认工作目录（`working_directory`）；会话可单独覆盖。空表示用户主目录。相对路径以当前会话解析后的目录为根 |
| `coding_mode` | bool | `false` | 编程模式，追加工程化系统提示词 |
| `max_read_bytes` | int | `1048576` | `read_file` / `search_text` 的单文件大小上限（字节） |
| `command_timeout_seconds` | int | `120` | `run_command` 超时 |
| `max_output_chars` | int | `20000` | 命令与 Git 输出截断长度 |
| `confirm_dangerous_tools` | bool | `false` | 开启后危险工具（`delete_path`、`git_commit`、`run_command`、`shell_command`、`run_applescript`、`myna_settings` 与鼠标 / 键盘控制工具）被硬拦截 |

## 电脑操作（computer use）

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `screen_access_enabled` | bool | `true` | 允许截屏 / OCR / 窗口列表 |
| `computer_control_enabled` | bool | `true` | 允许鼠标与键盘控制 |
| `screen_ocr_enabled` | bool | `true` | 截图后自动做本地 Vision OCR |

工具：`screenshot`、`read_screen`、`list_windows`、`activate_app`、`mouse_move`、`mouse_click`、`mouse_drag`、`scroll`、`key_press`、`type_text`、`wait`、`view_image`。

- 截屏需要「屏幕录制」权限；鼠标 / 键盘事件需要「辅助功能」权限。权限由 macOS 管理，Myna 只能发起申请并打开对应的系统设置页。
- 坐标使用全局屏幕点坐标、左上原点；截图尺寸是像素。`read_screen` 返回的文字框是相对截图的 0-1 比例。
- `view_image` 只在 `supports_vision = true` 时附加图片块；否则返回路径并提示改用 `read_screen`。
- 截图默认保存到 `~/.config/myna/screenshots/`（跟随 `MYNA_CONFIG`）。

## 自我控制 API

Myna 可以通过工具或 `myna api` 读写自身配置、权限与数据：

| 工具 | 动作 |
|---|---|
| `myna_settings` | `get` / `set` / `keys` / `backup` / `restore` / `backups` |
| `myna_permissions` | `status` / `request` / `open` |
| `myna_data` | `list` / `read` / `export` / `delete` |
| `skill_write` / `skill_delete` | 创建 / 更新 / 删除 `~/.config/myna/skills/<id>/SKILL.md` |
| `mcp_manage` | `list` / `add` / `remove` / `reload` / `call` |
| `plugin_manage` | `list` / `create` / `enable` / `disable` / `delete` |

配置写入规则：

1. 先把合并后的 JSON 解码回 `AppSettings`，再编码并比对目标键；类型或结构不匹配则拒绝，原文件保持不变。
2. 写入前备份到 `~/.config/myna/backups/config-<时间戳>.json`，默认保留最近 50 份；`restore` 可恢复任意一份。
3. 写盘后广播资源变更，下一次运行重建 Agent（保留对话历史），使新配置、新技能、新插件与新 MCP 工具生效。
4. 所有数据删除都会先备份；`myna_data` 只允许操作配置目录内的具名资源，拒绝包含 `/` 或 `..` 的 id。

## 语音输出

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `voice_enabled` | bool | `true` | 朗读回答 |
| `voice_language` | string | `zh-CN` | 识别与合成语言 |
| `voice_name` | string | `""` | 音色标识，空表示语言默认 |
| `voice_rate` | double | `0.5` | 语速 |
| `voice_volume` | double | `1.0` | 音量 |
| `voice_pitch` | double | `1.0` | 音调 |
| `speak_tool_results` | bool | `false` | 朗读工具执行结果 |

## 语音输入

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `silence_timeout` | double | `1.5` | 说完静音多少秒自动结束 |
| `no_speech_timeout` | double | `8.0` | 一直没说话多少秒放弃 |
| `auto_send_on_silence` | bool | `false` | 录音结束自动发送 |
| `continuous_mode` | bool | `false` | 回答朗读完自动接着听 |
| `listen_sound` | bool | `true` | 开始/结束录音播放提示音 |
| `hotkey_auto_send` | bool | `true` | 再次按快捷键结束时直接发送 |

## 外观

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `appearance` | string | `system` | `system` / `light` / `dark` |
| `accent` | string | `blue` | `blue`/`purple`/`pink`/`red`/`orange`/`yellow`/`green`/`graphite` |
| `font_size` | double | `13.0` | 聊天字号（pt） |
| `density` | string | `comfortable` | `compact` / `comfortable` |
| `show_timestamps` | bool | `false` | 显示时间戳 |
| `show_avatars` | bool | `true` | 显示头像与名称 |
| `markdown_enabled` | bool | `true` | 渲染 Markdown 与代码块 |
| `window_opacity` | double | `1.0` | 窗口/面板不透明度 |
| `bubble_corner_radius` | double | `12.0` | 气泡圆角 |
| `window_width` | double | `480` | 默认宽度（面板模式下也可拖拽调整） |
| `window_height` | double | `700` | 默认高度 |

## 对话

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `show_tool_calls` | bool | `true` | 显示工具调用 |
| `show_tool_results` | bool | `true` | 显示工具结果 |
| `show_errors` | bool | `true` | 显示错误消息 |
| `show_thinking` | bool | `true` | 显示思考过程 |
| `collapse_thinking` | bool | `true` | 思考区块默认收起 |
| `collapse_tools` | bool | `true` | 工具区块默认收起 |
| `send_on_enter` | bool | `true` | 回车发送；关闭则回车换行、`⌘回车`发送 |
| `auto_scroll` | bool | `true` | 自动滚动到最新消息 |
| `max_history_turns` | int | `20` | 内置运行时的上下文裁剪轮数，0 表示不限制 |
| `unlimited_history_turns` | bool | `false` | 勾选后忽略 `max_history_turns`，保留全部历史 |
| `clear_on_close` | bool | `false` | 关闭窗口时清空当前对话 |
| `background_runs` | bool | `true` | 切换会话/关闭面板时保持后台运行 |
| `max_parallel_runs` | int | `3` | 同时运行的会话数上限，超出时取消最旧的 |

## 行为

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `hotkey` | string | `option+space` | 主快捷键；需带修饰键或使用 F1–F12；支持 `double:option` 形式 |
| `hotkey_mode` | string | `toggle` | `toggle`（按下切换）或 `pushToTalk`（按住说话） |
| `hotkey_open` | string | `""` | 附加热键：只打开窗口 |
| `hotkey_clear` | string | `""` | 附加热键：清空对话 |
| `panel_mode` | bool | `true` | 下拉面板模式 |
| `resizable_panel` | bool | `true` | 面板模式下允许拖拽调整大小 |
| `always_on_top` | bool | `false` | 窗口始终置顶（面板模式不适用） |
| `launch_at_login` | bool | `true` | 开机自动启动 |
| `show_in_dock` | bool | `false` | 在 Dock 中显示图标 |
| `menu_bar_icon` | string | `custom` | `custom`（内置丝带 m 模板图）或 SF Symbol 名称 |
| `menu_bar_icon_size` | double | `15.0` | 菜单栏图标高度（pt） |
| `agent_runtime` | string | `auto` | `auto` / `package` / `builtin` |
| `disabled_tools` | string[] | `[]` | 禁用的工具名列表 |

## 环境变量

| 变量 | 覆盖 | 说明 |
|---|---|---|
| `DEEPSEEK_API_KEY` | `api_key` | |
| `MYNA_BASE_URL` | `base_url` | |
| `MYNA_MODEL` | `model` | |
| `MYNA_HUB_BASE` | — | 市场仓库地址（插入为最高优先级来源），用于镜像或离线测试 |
| `MYNA_MCP_CONFIG` | — | MCP 配置文件路径 |
| `MYNA_CONFIG` | — | 配置文件路径；技能、插件、方案、备份与截图跟随其父目录 |
| `MYNA_CONVERSATIONS` | — | 会话文件路径 |
| `MYNA_STALL_LOG` | — | 卡死快照路径 |
| `MYNA_SAFE_MODE_FILE` | — | 安全模式标记路径 |
| `MYNA_SIGN_IDENTITY` | — | 构建/发布时指定签名身份 |
| `MYNA_NOTARY_PROFILE` | — | 公证凭据 profile 名 |

环境变量只影响当前进程，不会写回配置文件。

### 网络搜索

| 键 | 默认 | 说明 |
|---|---|---|
| `search_provider` | `none` | `none` / `tavily` / `brave` / `serper` / `custom` |
| `search_api_key` | 空 | 服务商密钥 |
| `search_base_url` | 空 | 自定义服务商接口地址（含 `{query}` 时用 GET） |
| `search_max_results` | `5` | 返回条数（1–20） |
| `search_timeout_seconds` | `15` | 请求超时（秒，3–60） |
| `search_include_answer` | `false` | Tavily 是否返回综合答案 |

### 网络代理

| 键 | 默认 | 说明 |
|---|---|---|
| `proxy_enabled` | `false` | 是否启用代理 |
| `proxy_type` | `http` | `http` / `https` / `socks5` |
| `proxy_host` | 空 | 代理主机 |
| `proxy_port` | `0` | 代理端口（0 = 未启用） |
| `proxy_username` | 空 | 可选认证用户名 |
| `proxy_password` | 空 | 可选认证密码 |
| `proxy_bypass` | 空 | 绕过列表，逗号或空白分隔 |

### 更新

| 键 | 默认 | 说明 |
|---|---|---|
| `auto_check_updates` | `true` | 启动时自动检查更新（最多每 24 小时一次） |
| `last_update_check` | `0` | 上次检查时间（Unix 时间戳） |

详见 [network.md](network.md) 与 [models.md](models.md)。

## 性能

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `reduce_visual_effects` | bool | `false` | 关闭阴影与过渡动画。阴影需要每帧离屏模糊，关掉后滚动与流式更省电。 |
| `stream_plain_text` | bool | `false` | 流式期间用纯文本渲染，结束后自动恢复 Markdown 格式。 |
| `collapse_long_messages` | bool | `false` | 仅在需要极限性能时打开：超过 3000 字的消息折叠为 1500 字预览。**默认关闭**——消息应当完整显示，需要的是把「思考过程与工具调用」收起，而不是收起回答。 |
| `max_rendered_messages` | int | `0` | 消息列表最多渲染多少条，`0` 表示全部。超出部分折叠为「显示更早的消息」一行，数据本身不受影响。 |

在「设置 → 外观 → 性能」中提供这三项开关与一键「性能模式」（同时开启三项并保留最近 200 条）。

受控实测（500 条消息的历史、每秒 80 字的合成流式——接近真实模型速率、10 秒窗口，最终数据）：

| 设置 | CPU | 内存 |
| --- | --- | --- |
| 默认 | 2.25s / 10s（22%） | 112 MB |
| 性能模式 | 2.21s / 10s | 111 MB |

优化前同一场景为 6.68s / 10s（67%）、145 MB。另外，`MYNA_DEBUG_STREAM=<字符数>` 配合
`MYNA_DEBUG_STREAM_RATE=<字/秒>` 可以复现这组测量。

更早的一轮对照（每秒 600 字的合成流式、8 秒窗口，用于比较各项开关的相对收益）：

| 设置 | CPU | 内存 |
| --- | --- | --- |
| 默认 | 6.81s / 8s | 221 MB |
| 仅关闭阴影与动画 | 6.18s | 176 MB |
| 仅流式纯文本 | 6.44s | 215 MB |
| 仅渲染上限 200 条 | 6.40s | 219 MB |
| 性能模式（三项全开） | 3.22s | 176 MB |

## 卡死诊断

程序内置主线程看门狗（`Sources/Myna/StallWatchdog.swift`）：后台线程每秒向主队列投一次探针，
主线程被拖住超过 2.5 秒时，把现场快照追加到 `~/.config/myna/stall.log`：

```
[2026-10-20T06:58:44Z] 主线程阻塞 ≥5.0s (探针 5s 未回应)
body/s=0  气泡=0  会话=4  当前会话消息=0  运行中=false  流式长度=0  思考长度=0
窗口=906x745  面板模式=false  性能模式=false  渲染上限=0
```

`body/s` 是 `ChatView.body` 每秒的求值次数：数值异常**高**说明是 SwiftUI 更新循环；
数值很低（1~2）却仍然满 CPU，说明主线程卡在一次布局里出不来。

用 `MYNA_DEBUG_STALL=<秒数>` 可以在启动 12 秒后人为阻塞主线程，验证看门狗本身。

### 自动恢复与安全模式

主线程一旦卡死在一次布局里，进程内没有任何办法解开调用栈。因此看门狗在确认卡死
（探针 8 秒无回应）后会自动恢复：

1. 在 `~/.config/myna/stall.log` 落一份现场快照；
2. 写 `~/.config/myna/safe-mode.json`（记录原因、时间、重启次数）；
3. 退出当前进程，并让独立进程 1 秒后重新拉起 App。

下次启动即进入**安全模式**：关闭滚动观测、导航轨与悬停操作条，渲染条数压到 60 条，
界面顶部显示橙色提示条，点「恢复正常模式」即删除标记文件并重启回到完整界面。
安全模式只改界面渲染方式，不会改动用户配置。自动重启 10 分钟内最多触发一次，
避免「安全模式下同样卡住 → 无限重启」。

## 滚动性能实测

长会话滚动是当前架构的主要开销来源。用「上滚 → 回到底 → 再上滚」的确定性序列（6 轮、
约 1440 次滚动事件）在包含 14025 字消息的会话上测量：

| 实现 | 累计 CPU |
| --- | --- |
| 优化前（滚动几何写在 `@State`） | 26.98s |
| 滚动几何移入引用盒 + 导航轨按索引变化刷新 + 观测器去坐标换算 | 20.5s |
| 参考上限：完全关闭滚动观测（纯 SwiftUI 滚动） | 13.95s |

也就是说 SwiftUI 自身滚动这套内容就要约 10ms/事件；剩下的是我们可以继续压的部分。

已排除的非原因（均做过 A/B，差异在噪声内）：`.textSelection`、悬停/帮助区域、
`EquatableRow`、Markdown 解析（纯文本与 Markdown 同价）、语法高亮缓存。

## 关于「虚拟列表」的实测结论

消息列表用的是 `ScrollView + LazyVStack`。它**本身就是虚拟化的**：只有可见范围内的行会被创建，
滚动时按需创建新行。曾用 macOS 的 `List`（底层 `NSOutlineView`，真正复用行视图）做过对照实现，
在同一会话、同样 60 次滚动事件下测量：

| 实现 | 滚动距离 | CPU | 每 100px 成本 |
| --- | --- | --- | --- |
| `List`（NSOutlineView 复用） | 480px（且被夹住滚不动） | 0.65s | 0.14s |
| `ScrollView + LazyVStack` | 8243px | 1.23s | 0.01s |

`List` 在该布局下反而慢一个数量级，并且内容高度估算被钳制导致滚不到底，因此已回退。
结论：瓶颈不在「行是否复用」，而在于可见行本身的文本量——单条 5000 字以上的 Markdown
一次排版就是毫秒级到十几毫秒，滚动过程中会不断有新高行需要排版。

## 社区仓库来源（`hub_sources`）

市场不再绑定作者的 `myna-hub`：任何按约定提供 `registry.json` 的目录都可以作为来源。

```json
"hub_sources": [
  { "id": "myna-hub", "name": "Myna Hub",
    "base": "https://raw.githubusercontent.com/quyansiyuanwang/myna-hub/main/",
    "enabled": true },
  { "id": "team", "name": "团队镜像", "base": "file:///Users/me/hub/", "enabled": true }
]
```

- `registry.json` 与官方仓库同构：`{ "version": 1, "skills": [...], "mcps": [...], "plugins": [...] }`。
- **列表顺序即优先级**：同 `id` 条目以靠前的来源为准，重复条目不会重复显示。
- 安装时按条目回到它自己的来源取 `SKILL.md` / `mcp.json`，不会串源。
- 单个来源失败不影响其它来源：来源行会标注「失败」，鼠标悬停可看原因；全部失败时才在下方汇总报错。
- `enabled: false` 的来源不参与拉取，便于临时屏蔽。
- 环境变量 `MYNA_HUB_BASE` 仍可用：它会作为一个临时来源插到首位（不写回配置），便于镜像与离线测试。

界面：设置 → 市场 → 社区仓库，可增删来源、启停、查看每个来源的「采纳/总条目」数；来源多于一个时，顶部出现来源筛选，条目上会显示来源徽标。

命令行：

```
myna market-sources                          # 列出来源（按优先级）
myna market-sources add "团队镜像" owner/repo  # 支持 owner/repo、owner/repo@branch、https://…、/abs/path
myna market-sources disable <id>
myna market-sources remove <id>
myna market-install skill <id>               # 跨全部来源解析并安装
myna hub-check                               # 多来源合并自检（优先级/去重/失败隔离）
```
