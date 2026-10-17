# 编程模式

[返回主文档](../../README.zh-CN.md) · [配置项全表](config.md)

## 工作目录

「设置 → 工具 → 工作目录」指定一个目录（留空则为主目录）。所有文件工具的相对路径都以此为根。

## 编程模式

开启「编程模式」后，系统提示词会追加工程化指令：

- 先查看再修改，不臆造文件内容
- 小步、精确修改，优先使用精确字符串替换
- 改完运行构建或测试验证
- 汇报时说明改了哪些文件、验证结果如何
- 遵守工作目录边界

## 工具清单

| 工具 | 说明 |
|---|---|
| `read_file` | 读取文本文件，带行号，支持 `offset` / `limit` |
| `write_file` | 写入文件，可选自动创建父目录 |
| `edit_file` | 精确字符串替换（唯一匹配，或 `replace_all`） |
| `list_dir` | 列出目录内容（目录优先） |
| `find_files` | 通配符查找（`*`、`?`、`**`） |
| `search_text` | 递归内容搜索，输出 `file:line: 文本` |
| `make_dir` / `move_path` | 建目录 / 移动 |
| `delete_path` | 删除（**危险**，目录需 `recursive: true`） |
| `git_status` / `git_diff` / `git_log` | 查看仓库状态、差异、历史 |
| `git_commit` | 提交（**危险**，默认 `git add -A`） |
| `run_command` | 在工作目录执行 shell 命令（构建、测试），**危险** |

输出与超时受 `max_output_chars`、`command_timeout_seconds`、`max_read_bytes` 约束。

## 安全

危险工具在「设置 → 工具」中带红色「危险」标记：

`delete_path`、`git_commit`、`run_command`、`shell_command`、`run_applescript`

开启 `confirm_dangerous_tools` 后，这些工具会被**硬拦截**，返回要求模型先征得用户确认的提示。也可以在「设置 → 工具」中直接停用任意工具。

## 典型工作流

```
1. list_dir / search_text   定位相关文件
2. read_file                读取上下文
3. edit_file                精确修改
4. run_command              构建或测试验证
5. git_diff / git_status    确认改动
6. git_commit               提交（如需要）
```

## 长任务与子代理

对于较长的多步任务，建议：

- 开启「无限轮数」，避免轮次上限打断
- 用 `run_subagent` 把自包含子任务交给独立上下文的子代理，避免污染主对话
- 用 `run_subagents` 并行处理可拆分的工作
- 开启「后台运行」，这样切到别的会话也不会中断当前任务
