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

「设置 → 模型」左侧是供应商列表（当前供应商打勾），可新建、复制、删除，并在右侧编辑名称 / 协议 / 地址 / Key；右侧是所选供应商的模型列表：

| 操作 | 说明 |
|---|---|
| 添加 | 手动输入模型 id（发送给接口的模型名） |
| 探测并添加 | 请求该供应商的模型列表接口，按 id 去重后并入（标记为「探测」） |
| 应用 | 把该模型设为当前：供应商的协议 / 地址 / Key 与模型的 id / 推理参数 / 采样参数写入顶层扁平字段 |
| 编辑 | 显示名、最大 tokens（0 = 全局）、温度（-1 = 全局）、上下文窗口 |
| 复制 / 删除 | 复制一份或删除该模型 |

模型条目字段：`id`、`name`（模型 id）、`display_name`、`reasoning_effort`、`thinking_budget`、`max_tokens`、`temperature`、`context_window`、`discovered`。

顶层的扁平字段（`base_url` / `api_key` / `model` / `api` 与推理、采样参数）始终是**当前生效**的配置；直接编辑它们同样生效，且不会回写已保存的供应商。

顶栏模型菜单按**供应商 → 模型**两级展开，点模型即切换。

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

## 推理强度

不同协议暴露方式不同：

| 协议 | 设置项 | 说明 |
|---|---|---|
| openai-responses | 推理强度 | 以 `reasoning.effort` 发送：`minimal`/`low`/`medium`/`high`/`xhigh`/`max`，选「关闭」不发送 |
| anthropic-messages | 思考预算 | 以 `thinking.budget_tokens` 发送，0 = 关闭；提供 1k/4k/8k/16k/32k 预设 |
| google-generative-ai | 思考预算 | 以 `generationConfig.thinkingConfig.thinkingBudget` 发送 |
| openai-completions | 无 | 推理由模型自身决定，选择带推理能力的模型即可 |

修改后会重建 Agent，下一条消息即生效。

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
