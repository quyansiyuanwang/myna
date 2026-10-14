#!/bin/bash
# 构建 AiSiri.app（无需 Xcode，使用 SwiftPM + 命令行工具链）
set -e
cd "$(dirname "$0")"

echo "==> 编译 Release"
swift build -c release

BIN=".build/release/AiSiri"
APP="$HOME/Applications/AiSiri.app"

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AiSiri"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> 签名"
IDENTITY="${AISIRI_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.+)".*/\1/')
fi
if [ -n "$IDENTITY" ]; then
  echo "    Developer ID: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" --entitlements Resources/AiSiri.entitlements "$APP"
else
  echo "    临时签名（ad-hoc；未找到 Developer ID 证书）"
  codesign --force --sign - --entitlements Resources/AiSiri.entitlements "$APP" 2>/dev/null || \
  codesign --force --sign - "$APP"
fi

echo "==> 初始化配置 ~/.config/aisiri/config.json"
mkdir -p "$HOME/.config/aisiri"
if [ ! -f "$HOME/.config/aisiri/config.json" ]; then
  cp config.example.json "$HOME/.config/aisiri/config.json"
  echo "⚠️  请打开 App「设置 → 模型」填入 API Key（或先 export DEEPSEEK_API_KEY 再运行本脚本）"
fi
chmod 600 "$HOME/.config/aisiri/config.json" 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/AiSiri" "$HOME/.local/bin/aisiri"

echo ""
echo "✅ 完成"
echo "  App:    $APP"
echo "  CLI:    $HOME/.local/bin/aisiri"
echo "  配置:   $HOME/.config/aisiri/config.json"
