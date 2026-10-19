# 网络搜索、代理与 MCP

本文档说明 Myna 的三项网络能力：联网搜索、网络代理，以及 MCP 服务器配置。
全部配置位于「设置 → 工具」，配置文件为 `~/.config/myna/config.json`（权限 0600）。

---

## 一、联网搜索

模型通过 `web_search` 工具联网检索，通过 `fetch_url` 抓取网页正文。
未配置服务商时，`web_search` 会返回提示要求先配置，**不会静默打开浏览器**。

### 支持的服务商

| 服务商 | 配置项 | 说明 |
|---|---|---|
| Tavily | `search_api_key` | `POST https://api.tavily.com/search`；可额外返回综合答案 |
| Brave | `search_api_key` | `GET https://api.search.brave.com/res/v1/web/search`，使用 `X-Subscription-Token` 头 |
| Serper | `search_api_key` | `POST https://google.serper.dev/search`，使用 `X-API-KEY` 头 |
| 自定义 | `search_api_key` + `search_base_url` | 见下 |

### 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `search_provider` | `none` | `none` / `tavily` / `brave` / `serper` / `custom` |
| `search_api_key` | 空 | 服务商密钥；`custom` 时可选 |
| `search_base_url` | 空 | 自定义接口地址 |
| `search_max_results` | `5` | 返回条数，1–20 |
| `search_timeout_seconds` | `15` | 请求超时（秒），3–60 |
| `search_include_answer` | `false` | Tavily：是否请求综合答案 |

### 自定义服务商

- 地址中含 `{query}` 占位符时，使用 **GET** 并在该处拼接关键词；
- 否则使用 **POST**，请求体为 `{"query": "...", "max_results": N}`；
- 两种情况都会带上 `Authorization: Bearer <key>`。

响应解析会尽力兼容常见结构：`results` / `items` / `organic` / `data`，
每项取 `title`、`url`（或 `link`）、`snippet`（或 `content` / `description`）。

### 错误提示

| 情况 | 提示 |
|---|---|
| HTTP 401 / 403 | API Key 无效或无权限 |
| HTTP 429 | 请求过于频繁（限流） |
| HTTP 5xx | 服务商暂时不可用 |
| 超时 / 离线 | 网络请求失败，请检查网络或代理设置 |

---

## 二、网络代理

开启后，**所有出网请求**都会经代理：模型请求、联网搜索、`fetch_url`、更新检查。

| 键 | 默认 | 说明 |
|---|---|---|
| `proxy_enabled` | `false` | 是否启用 |
| `proxy_type` | `http` | `http` / `https` / `socks5` |
| `proxy_host` | 空 | 代理主机 |
| `proxy_port` | `0` | 代理端口；为 0 时视为未启用 |
| `proxy_username` | 空 | 可选，留空表示无认证 |
| `proxy_password` | 空 | 可选 |
| `proxy_bypass` | 空 | 绕过代理的主机列表，逗号或空白分隔 |

说明：

- 认证键名遵循 CFNetwork 约定：HTTP 使用 `HTTPProxyUsername` / `HTTPProxyPassword`，
  SOCKS 使用 `SOCKSUser` / `SOCKSPassword`；
- `proxy_type = http` 会同时设置 HTTP 与 HTTPS 代理（多数本机代理如 Clash / Surge 属于此类）；
- 主机为空或端口为 0 时不会生成代理配置，等同于关闭；
- 设置界面提供「测试代理」按钮，请求 `https://api.github.com/zen` 并显示往返耗时。

---

## 三、MCP 服务器

MCP（Model Context Protocol）服务器通过 stdio 启动，其工具以
`mcp__<服务器>__<工具>` 的形式暴露给模型。

### 配置文件

`~/.config/myna/mcp.json`：

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/work"],
      "env": { "FOO": "bar" }
    }
  }
}
```

可用环境变量 `MYNA_MCP_CONFIG` 覆盖配置路径。

### 界面管理

「设置 → 工具 → MCP 服务器」支持：

- 列出已配置服务器，显示命令摘要与已加载的工具数量（未加载时显示「未加载」）；
- **添加服务器** / **编辑** / **删除**（表单支持名称、命令、参数逐行填写、环境变量 `KEY=VALUE` 逐行填写）；
- **重新加载**：修改后立即重载，无需重启应用；
- **打开配置文件**：在访达中定位 `mcp.json`。

也可以在「设置 → 市场」一键安装社区 MCP 服务器。

### 排查

- 命令必须是本机可执行文件（`npx`、`uvx`、`node` 或绝对路径）；
- 服务器启动失败时，其工具数量显示为「未加载」，可在终端手动执行相同命令查看报错；
- 需要联网拉取包的服务器（如 `npx -y ...`）若处于受限网络，请先配置网络代理。
