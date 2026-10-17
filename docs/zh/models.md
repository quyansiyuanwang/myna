# 模型与推理

[返回主文档](../../README.zh-CN.md) · [配置项全表](config.md)

## 接口类型

Myna 按**协议**而不是厂商来组织配置，共支持四种：

| `api` | 说明 |
|---|---|
| `openai-completions` | OpenAI Chat Completions 兼容端点（DeepSeek、OpenAI、Ollama、vLLM 等） |
| `openai-responses` | OpenAI Responses API |
| `anthropic-messages` | Anthropic Messages API |
| `google-generative-ai` | Google Generative AI（Gemini） |

四种协议都由 [pi-ai-swift](https://github.com/quyansiyuanwang/pi-ai-swift) 原生实现，无需任何代理或转换层。

> 内置兜底运行时（`agent_runtime = builtin`）只支持 `openai-completions`；选择其他协议时会自动走 Swift 包运行时。

## 供应商与模型

模型按**供应商**组织：每个供应商有自己的名称、接口协议、地址、API Key，以及属于它的模型列表。

「设置 → 模型」是一棵**供应商 → 模型**整合树：点供应商行体即把它设为当前供应商（打勾并显示「当前」徽标），点箭头展开后可就地编辑名称 / 协议 / 地址 / Key，并管理该供应商的模型：

| 操作 | 说明 |
|---|---|
| 添加 | 手动输入模型 id（发送给接口的模型名） |
| 探测并添加 | 请求该供应商的模型列表接口，按 id 去重后并入（标记为「探测」） |
| 选中 | 点模型行即把该模型设为当前：供应商的协议 / 地址 / Key 与模型的 id / 推理参数 / 采样参数写入顶层扁平字段 |
| 编辑 | 显示名、最大 tokens（0 = 全局）、温度（-1 = 全局）、上下文窗口、可用思考强度（芯片）、默认等级、思考预算 |
| 复制 / 删除 | 复制一份或删除该模型 |

模型条目字段：`id`、`name`（模型 id）、`display_name`、`reasoning_effort`（该模型选中的思考等级）、`thinking_levels`（该模型声明支持的等级）、`thinking_budget`、`max_tokens`、`temperature`、`context_window`、`discovered`。供应商另有 `selected_model_id`，记住该供应商上次使用的模型，切换回来时自动恢复。

顶层的扁平字段（`base_url` / `api_key` / `model` / `api` 与推理、采样参数）始终是**当前生效**的配置；直接编辑它们同样生效，且不会回写已保存的供应商。

顶栏模型菜单是同一棵**供应商 → 模型**树：点供应商行切换供应商并记忆其上次使用的模型，点模型行切换模型，两者都会关闭弹窗。

## 配置方案

配置方案保存的是**全部设置**（供应商与模型、外观、语音、对话、行为、工具、系统提示词等），而不只是模型。每个方案是 `~/.config/myna/profiles/<名称>.json` 里的一份完整配置快照。

「设置 → 配置」可保存当前为新方案、应用、重命名、删除、导出 / 导入方案，以及导出 / 导入完整配置（直接读写 `config.json` 的内容）。顶栏弹窗的第一个分区也会列出全部方案，点一下即可整体切换。

> 从旧版本升级时，首次加载会把旧的 `model_profiles` / `model_list` 自动迁移成供应商与模型，并把这两个键写回空数组。

## 模型探测

选中供应商后点「探测并添加」（或命令行 `myna models`）会按该供应商的协议请求端点：

| 协议 | 请求 |
|---|---|
| openai-completions / openai-responses | `GET {base_url}/models` |
| anthropic-messages | `GET {base_url}/v1/models` |
| google-generative-ai | `GET {base_url}/v1beta/models` |

结果按 id 去重后并入该供应商的模型列表（标记为「探测」）。命令行等价：

```sh
myna models
```

## 思考强度

每个模型可以声明自己支持的**思考等级**（`thinking_levels`），并按协议映射到具体请求参数。规范等级共七级，顺序固定：

`off` → `minimal` → `low` → `medium` → `high` → `xhigh` → `max`

界面显示名依次为：关闭 / 极简 / 低 / 中 / 高 / 极高 / 最大。

在「设置 → 模型」里编辑某个模型时，可以：

- **可用思考强度**：用芯片逐个启用 / 停用该模型支持的等级（点击即保存，保留规范顺序并去重）；
- **默认等级**：在已启用的等级中选择该模型当前使用的等级（写入 `reasoning_effort`）；
- **思考预算**（仅 Anthropic / Gemini）：显式覆盖思考预算，`0` 表示由等级推导。

### 请求参数映射

| 协议 | 发送方式 | 新建模型时的默认等级 |
|---|---|---|
| `openai-completions` | 以 `reasoning_effort` 发送所选等级（`off` 不发送） | `off`/`minimal`/`low`/`medium`/`high` |
| `openai-responses` | 以 `reasoning.effort` 发送所选等级（`off` 不发送） | 全部七级 |
| `anthropic-messages` | 以 `thinking.budget_tokens` 发送解析后的预算 | `off`/`low`/`medium`/`high`/`xhigh`/`max` |
| `google-generative-ai` | 以 `generationConfig.thinkingConfig.thinkingBudget` 发送解析后的预算 | 同 Anthropic |

预算协议下，预算优先取模型的 `thinking_budget`（`> 0`），否则由所选等级推导：

| 等级 | off | minimal | low | medium | high | xhigh | max |
|---|---|---|---|---|---|---|---|
| 预算（tokens） | 0 | 1024 | 2048 | 4096 | 8192 | 16384 | 32768 |

### 在聊天中切换

聊天顶栏的模型名右侧有一个「思考 高」按钮，点开后**只列出当前模型声明的等级**，点一下即可切换。切换会同时写入模型条目与顶层扁平字段，下一条消息生效；Agent 会按新配置重建，但对话上下文会保留。

若当前模型未声明任何等级，该按钮禁用，提示「该模型未声明可用的思考强度」，可在「供应商与模型 → 模型 → 编辑」中添加。

## 采样参数

| 参数 | 默认 | 说明 |
|---|---|---|
| 温度 | 0.7 | 越高越随机 |
| Top P | 1.0 | 核采样 |
| 频率惩罚 | 0.0 | 抑制重复用词 |
| 存在惩罚 | 0.0 | 鼓励新话题 |
| 最大 tokens | 8192 | 单次输出上限 |
| 失败重试 | 2 | 网络错误与 429/5xx 的退避重试 |

所有参数在**每次请求时注入**，调整它们不会重建 Agent、不会丢失对话上下文。

## 上下文与轮数

| 设置 | 说明 |
|---|---|
| 工具执行最大轮数 | 单次提问最多执行多少次工具；`0` 表示不限制 |
| 无限轮数 | 勾选后始终不限制（长任务、复杂任务建议开启） |
| 保留最近对话轮数 | 内置运行时的上下文裁剪，0 = 不限制 |

> Swift 包运行时的上下文由 PiAgentCore 自行管理；`保留最近对话轮数` 仅对内置运行时生效。
