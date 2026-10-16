#!/bin/bash
# 构建 Myna.app（无需 Xcode，使用 SwiftPM + 命令行工具链）
set -e
cd "$(dirname "$0")"

echo "==> 编译 Release"
swift build -c release

BIN=".build/release/Myna"
APP="$HOME/Applications/Myna.app"

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Myna"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/Myna.icns ]; then
  cp Resources/Myna.icns "$APP/Contents/Resources/Myna.icns"
fi
if [ -f Resources/MenuBarTemplate.png ]; then
  cp Resources/MenuBarTemplate.png "$APP/Contents/Resources/MenuBarTemplate.png"
fi
if [ -f "Resources/MenuBarTemplate@2x.png" ]; then
  cp "Resources/MenuBarTemplate@2x.png" "$APP/Contents/Resources/MenuBarTemplate@2x.png"
fi

echo "==> 签名"
IDENTITY="${MYNA_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.+)".*/\1/')
fi
if [ -n "$IDENTITY" ]; then
  echo "    Developer ID: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" --entitlements Resources/Myna.entitlements "$APP"
else
  echo "    临时签名（ad-hoc；未找到 Developer ID 证书）"
  codesign --force --sign - --entitlements Resources/Myna.entitlements "$APP" 2>/dev/null || \
  codesign --force --sign - "$APP"
fi

echo "==> 初始化配置 ~/.config/myna/config.json"
mkdir -p "$HOME/.config/myna"
CONFIG="$HOME/.config/myna/config.json"
LEGACY="$HOME/.config/aisiri/config.json"
if [ ! -f "$CONFIG" ]; then
  if [ -f "$LEGACY" ]; then
    cp "$LEGACY" "$CONFIG"
    echo "已从旧版 AiSiri 迁移配置"
  else
    cp config.example.json "$CONFIG"
    echo "⚠️  请打开 App「设置 → 模型」填入 API Key（或先 export DEEPSEEK_API_KEY 再运行本脚本）"
  fi
fi
chmod 600 "$CONFIG" 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/Myna" "$HOME/.local/bin/myna"

echo ""
echo "✅ 完成"
echo "  App:    $APP"
echo "  CLI:    $HOME/.local/bin/myna"
echo "  配置:   $HOME/.config/myna/config.json"
