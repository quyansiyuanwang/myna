#!/bin/bash
# MCP 端到端自检。
#
# 启动一个极小的 Python MCP 服务器（stdio + 换行分隔 JSON），把 Myna 指向它，
# 然后通过 `myna tool mcp__<server>__<tool>` 验证调用链：
#   配置加载 → 子进程启动 → initialize 握手 → tools/list → tools/call
# 任一环节不符合预期即以非零码退出。
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${MYNA_BIN:-.build/debug/Myna}"
if [ ! -x "$BIN" ]; then
  echo "==> 未找到 $BIN，先执行 swift build"
  swift build
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 写入临时 MCP 服务器"
cat > "$TMP/server.py" <<'PY'
#!/usr/bin/env python3
"""最小 MCP 服务器：支持 initialize / tools/list / tools/call(echo)。"""
import json
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        msg = json.loads(raw)
    except ValueError:
        continue
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "selftest", "version": "1.0"},
        }})
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
            "name": "echo",
            "description": "回显输入文本",
            "inputSchema": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
            },
        }]}})
    elif method == "tools/call":
        params = msg.get("params") or {}
        args = params.get("arguments") or {}
        if params.get("name") == "echo":
            text = args.get("text", "")
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text", "text": "echo: %s" % text}],
                "isError": False,
            }})
        else:
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text", "text": "unknown tool"}],
                "isError": True,
            }})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid,
              "error": {"code": -32601, "message": "method not found: %s" % method}})
PY

echo "==> 写入临时配置 $TMP/mcp.json"
cat > "$TMP/mcp.json" <<JSON
{
  "servers": {
    "selftest": {
      "command": "python3",
      "args": ["$TMP/server.py"],
      "env": {}
    }
  }
}
JSON

export MYNA_MCP_CONFIG="$TMP/mcp.json"

echo "==> 调用 mcp__selftest__echo"
OUT="$("$BIN" tool mcp__selftest__echo '{"text":"hello"}')"
echo "    输出: $OUT"
if [ "$OUT" != "echo: hello" ]; then
  echo "❌ 自检失败：期望 'echo: hello'，实际 '$OUT'" >&2
  exit 1
fi

echo "==> 调用不存在的工具应返回可读错误"
ERR="$("$BIN" tool mcp__selftest__missing '{}')"
echo "    输出: $ERR"
case "$ERR" in
  *"未知的 MCP 工具"*) ;;
  *)
    echo "❌ 自检失败：未知工具未返回预期错误：$ERR" >&2
    exit 1
    ;;
esac

echo "==> myna tools 应列出命名空间化工具"
TOOLS="$("$BIN" tools)"
if ! printf '%s\n' "$TOOLS" | grep -q '^mcp__selftest__echo'; then
  echo "❌ 自检失败：myna tools 未列出 mcp__selftest__echo" >&2
  exit 1
fi

echo "✅ MCP 自检通过"