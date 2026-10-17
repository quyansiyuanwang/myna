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

## 模型档案

「设置 → 模型 → 模型列表」可保存多套配置，每套包含：名称、接口类型、地址、Key、模型、推理参数、最大 tokens、温度。

| 操作 | 说明 |
|---|---|
| 新建 | 把当前生效配置存为新档案 |
| 更新当前 | 把顶层字段回写到选中的档案 |
| 复制 | 复制一份（名称加「副本」） |
| 删除 | 删除档案（不影响顶层配置） |
| 应用 | 把档案值写入顶层字段并切换过去 |

顶栏的模型菜单会**先列档案、再列最近使用**，点一下即可切换。

## 模型探测

点「探测模型」会按当前协议请求端点：

| 协议 | 请求 |
|---|---|
| openai-completions / openai-responses | `GET {base_url}/models` |
| anthropic-messages | `GET {base_url}/v1/models` |
| google-generative-ai | `GET {base_url}/v1beta/models` |

结果可搜索、可缓存（按 `协议|地址` 缓存，重新打开无需再请求）。命令行等价：

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
