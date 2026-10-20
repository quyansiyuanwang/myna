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
| `MYNA_HUB_BASE` | — | 市场仓库地址，用于镜像或离线测试 |
| `MYNA_MCP_CONFIG` | — | MCP 配置文件路径 |
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
