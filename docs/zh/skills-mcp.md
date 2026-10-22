# 技能、提示词与 MCP

[返回主文档](../../README.zh-CN.md) · [配置项全表](config.md)

## 提示词模板

在 `~/.config/myna/prompts/` 放置 `.md` 文件：

```markdown
# 总结剪贴板
读取剪贴板内容，用 3 条要点总结。
```

- 首行 `# 标题` 作为菜单中显示的名称，否则使用文件名
- 输入栏的模板菜单点击即插入输入框（**不会自动发送**），便于先修改
- 菜单中还有「重新扫描」与「打开模板目录」

## 技能

每个技能一个子目录，内含 `SKILL.md`：

```
~/.config/myna/skills/daily-report/SKILL.md
```

```markdown
---
name: 日报生成
description: 汇总今天的提醒与日程，生成一段日报文本
---
1. 调用 `get_datetime` 获取今天的日期。
2. 调用 `run_applescript` 查询提醒事项中今天到期的条目。
3. 整理成「已完成 / 进行中 / 明日关注」三段。
```

- `name` 与 `description` 必填；`description` 会**注入系统提示词**
- 模型在需要时用 `read_skill` 工具读取完整步骤；`list_skills` 可列出全部
- 正文应写成具体、可执行的步骤，工具名用反引号标注

### 兼容 pi 的技能

Myna 同时扫描 `~/.pi/agent/skills/`，格式相同。同 id 时以 Myna 目录优先，因此可以直接复用 pi 生态的技能。

## MCP 服务器

在 `~/.config/myna/mcp.json` 中登记（首次运行会生成模板与 `mcp.README.md`）：

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

- `command` 经 `/usr/bin/env` 启动，支持 `npx`、`uvx` 或绝对路径
- `args` 为字符串数组，`env` 为附加环境变量
- 工具以 `mcp__<服务器>__<工具>` 暴露，例如 `mcp__filesystem__read_text_file`
- 修改配置后重启应用，或在代码中调用 `MCPManager.shared.reload()`
- 服务器 stderr 会带 `[mcp:<服务器>]` 前缀输出，便于排错

命令行验证：

```sh
myna tools | grep mcp__
myna tool mcp__filesystem__read_text_file '{"path":"/tmp/a.txt"}'
```

自检脚本：`./scripts/mcp-selftest.sh`

## 市场

「设置 → 市场」可以同时接入多个来源。来源只需提供一个 `registry.json`：

```json
{ "version": 1, "skills": [...], "mcps": [...], "plugins": [...] }
```

内置来源是 [myna-hub](https://github.com/quyansiyuanwang/myna-hub)，其中按目录管理三类内容：

| 目录 | 内容 |
|---|---|
| `skills/` | 技能 |
| `mcps/` | MCP 服务器定义 |
| `plugins/` | 插件：引用已有的技能与 MCP |

来源可以是 `owner/repo[@branch]`、任意 `https://` 基址或本地 `file://` 目录。列表顺序决定优先级：同 `id` 条目以靠前的来源为准，安装时回到条目自己的来源取文件；单个来源失败只在来源行标注，不影响其他来源。安装插件会一并安装其引用的技能与 MCP。命令行等价：

```sh
myna market-sources list
myna market-sources add team https://example.org/hub
myna market-install skill daily-report
myna market-install mcp memory
myna market-install plugin morning-routine
```

## 让 Myna 自己创建

Myna 可以在运行时为自己写资源，下一次运行即生效：

```sh
myna api skill.write '{"id":"daily","name":"日报","description":"生成日报","body":"步骤……"}'
myna api plugin.create '{"id":"pack","name":"工作包","instructions":"回答保持简短","skills":["daily"]}'
myna api mcp.add '{"id":"fs","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"]}'
```

对应工具为 `skill_write` / `skill_delete` / `plugin_manage` / `mcp_manage`。本地插件写在 `~/.config/myna/plugins/<id>.json`，启用时把 `instructions` 追加到系统提示词；MCP 添加后可用 `mcp_manage action=call` 立即调用，工具列表在重载完成后进入下一次运行的 Agent。

仓库通过 CI 校验一致性（frontmatter、id、MCP 字段形状、插件引用、registry 同步），贡献方式见仓库内的 `CONTRIBUTING.md`。
