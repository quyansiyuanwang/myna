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
| `reasoning_effort` | string | `""` | 仅 `openai-responses`：`minimal`/`low`/`medium`/`high`/`xhigh`/`max`，空表示不发送 |
| `thinking_budget` | int | `0` | 仅 Anthropic / Gemini：思考预算 token 数，0 表示关闭 |
| `recent_models` | string[] | `[]` | 最近使用过的模型 |
| `model_list` | string[] | `[]` | 手动录入与探测积累的模型列表，顶栏弹窗中切换 |
| `model_profiles` | object[] | `[]` | 模型档案，见下 |
| `active_profile_id` | string \| null | `null` | 当前选中的档案 id |
| `max_tokens` | int | `8192` | 单次输出上限 |
| `temperature` | double | `0.7` | 温度 |
| `top_p` | double | `1.0` | 核采样 |
| `frequency_penalty` | double | `0.0` | 频率惩罚 |
| `presence_penalty` | double | `0.0` | 存在惩罚 |
| `max_retries` | int | `2` | 网络错误与 429/5xx 的重试次数（两个运行时都生效） |
| `max_tool_rounds` | int | `8` | 每次提问的工具执行轮数上限；**`0` 表示不限制** |
| `unlimited_tool_rounds` | bool | `false` | 勾选后忽略 `max_tool_rounds`，始终不限制 |
| `system_prompt` | string | 内置 | 系统提示词 |

### 模型档案字段

`model_profiles` 数组中的每一项：

| 键 | 类型 | 说明 |
|---|---|---|
| `id` | string | UUID |
| `name` | string | 显示名称 |
| `base_url` / `api_key` / `model` / `api` | string | 同顶层字段 |
| `reasoning_effort` | string | 同顶层 |
| `thinking_budget` | int | 同顶层 |
| `max_tokens` | int | 同顶层 |
| `temperature` | double | 同顶层 |

顶层的扁平字段是**当前生效配置**；选择档案时会把档案值复制到顶层字段，编辑顶层字段不会自动回写档案（需点「更新当前」）。

## 子代理

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `subagent_timeout_seconds` | int | `300` | 单个子代理超时 |
| `subagent_max_rounds` | int | `16` | 子代理工具轮数上限 |
| `subagent_max_parallel` | int | `3` | `run_subagents` 的并行上限 |

## 编程

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `working_directory` | string | `""` | 工作目录；空表示用户主目录。相对路径以此为根 |
| `coding_mode` | bool | `false` | 编程模式，追加工程化系统提示词 |
| `max_read_bytes` | int | `1048576` | `read_file` / `search_text` 的单文件大小上限（字节） |
| `command_timeout_seconds` | int | `120` | `run_command` 超时 |
| `max_output_chars` | int | `20000` | 命令与 Git 输出截断长度 |
| `confirm_dangerous_tools` | bool | `false` | 开启后危险工具（`delete_path`、`git_commit`、`run_command`、`shell_command`、`run_applescript`）被硬拦截 |

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
| `MYNA_HUB_BASE` | — | 市场仓库地址，用于镜像或离线测试 |
| `MYNA_MCP_CONFIG` | — | MCP 配置文件路径 |
| `MYNA_SIGN_IDENTITY` | — | 构建/发布时指定签名身份 |
| `MYNA_NOTARY_PROFILE` | — | 公证凭据 profile 名 |

环境变量只影响当前进程，不会写回配置文件。
