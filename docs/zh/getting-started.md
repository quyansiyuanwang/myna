# 快速开始

[返回主文档](../../README.zh-CN.md) · [配置项全表](config.md)

## 1. 安装

```sh
brew install --cask quyansiyuanwang/tap/myna
```

或从 [Releases](https://github.com/quyansiyuanwang/myna/releases) 下载后：

```sh
xattr -dr com.apple.quarantine /Applications/Myna.app
```

从源码构建：`git clone` 后执行 `./build.sh`。

## 2. 首次启动

启动后应用只出现在**菜单栏**（默认不在 Dock 显示）。点击菜单栏图标即可打开下拉面板。

## 3. 授予权限

首次使用相关功能时系统会弹窗，也可手动到「系统设置 → 隐私与安全性」授权：

| 权限 | 何时需要 |
|---|---|
| 麦克风、语音识别 | 语音输入 |
| 辅助功能 | 双击修饰键、模拟键盘输入 |
| 自动化 | 通过 AppleScript 控制其他应用 |
| 屏幕录制 | 截图类工具 |

> 说明：应用为 ad-hoc 签名，每次重新编译后签名会变化，系统可能重新询问权限。使用稳定安装版本不会反复弹窗。

## 4. 填入 API Key

打开「设置 → 模型」：

1. 选择**接口类型**（默认 `openai-completions`，兼容 DeepSeek / OpenAI / Ollama 等）
2. 填入 **API 地址**与 **API Key**
3. 点「**探测模型**」拉取端点可用模型，或直接手填模型名
4. 点「**测试连接**」确认可用

也可以只设环境变量（不会写回配置）：

```sh
export DEEPSEEK_API_KEY=sk-xxxx
```

## 5. 第一个对话

在面板输入框打字，或按 `⌥Space` 说话。回车发送。

试试这些：

- 打开计算器，把音量调到 30
- 播放周杰伦的歌
- 明天 9 点提醒我开会
- 查一下电池状态
- 截个屏并读一下剪贴板

## 6. 下一步

- [模型与推理](models.md)：多套模型档案、推理强度、采样参数
- [语音与快捷键](voice.md)：快捷键录入、双击修饰键、长按说话
- [技能与 MCP](skills-mcp.md)：扩展模型能力
- [编程模式](coding.md)：让 Myna 读改代码、跑构建
- [常见问题](faq.md)
