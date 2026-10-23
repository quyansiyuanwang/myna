#!/bin/bash
# 构建 Myna.app（无需 Xcode，使用 SwiftPM + 命令行工具链）
set -e
cd "$(dirname "$0")"

echo "==> 编译 Release"
swift build -c release

BIN=".build/release/Myna"
FINAL_APP="$HOME/Applications/Myna.app"
# 先在临时 bundle 里完成打包与签名，最后整体替换。这样即使 Myna 正在运行，
# codesign 也不会因为目标二进制正在使用而失败（"Operation not permitted"）。
APP="$HOME/Applications/.Myna-staging.app"

echo "==> 打包 $FINAL_APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Myna"
# 去除调试符号（必须在签名前；strip 会使已有签名失效）
if command -v strip >/dev/null 2>&1; then
  strip -x "$APP/Contents/MacOS/Myna" 2>/dev/null || true
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 本地构建写入版本号（取最近的 tag，去掉前缀 v）；Info.plist 的占位值会导致更新检查误判
LOCAL_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
[ -z "$LOCAL_VERSION" ] && LOCAL_VERSION="0.0.0-dev"
plutil -replace CFBundleShortVersionString -string "$LOCAL_VERSION" "$APP/Contents/Info.plist" 2>/dev/null || true
plutil -replace CFBundleVersion -string "$LOCAL_VERSION" "$APP/Contents/Info.plist" 2>/dev/null || true
echo "    版本: $LOCAL_VERSION"
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
SIGN_KEYCHAIN=""
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.+)".*/\1/')
fi
# 本地稳定签名：自签名证书的 designated requirement 是「bundle id + 证书叶哈希」，
# 不随每次构建的 cdhash 变化，TCC 授权才能在更新后保留。
LOCAL_KEYCHAIN="$HOME/Library/Keychains/myna-signing.keychain-db"
LOCAL_PASSWORD_FILE="$HOME/Library/Application Support/Myna/signing/password"
if [ -z "$IDENTITY" ] && [ -f "$LOCAL_KEYCHAIN" ] && [ -f "$LOCAL_PASSWORD_FILE" ]; then
  security unlock-keychain -p "$(cat "$LOCAL_PASSWORD_FILE")" "$LOCAL_KEYCHAIN" >/dev/null 2>&1 || true
  if security find-identity -p codesigning "$LOCAL_KEYCHAIN" 2>/dev/null | grep -q "Myna Local Code Signing"; then
    IDENTITY="Myna Local Code Signing"
    SIGN_KEYCHAIN="$LOCAL_KEYCHAIN"
  fi
fi
if [ -n "$IDENTITY" ]; then
  echo "    签名身份: $IDENTITY"
  if [ -n "$SIGN_KEYCHAIN" ]; then
    codesign --force --options runtime --keychain "$SIGN_KEYCHAIN" \
      --sign "$IDENTITY" --entitlements Resources/Myna.entitlements "$APP"
  else
    codesign --force --options runtime --timestamp \
      --sign "$IDENTITY" --entitlements Resources/Myna.entitlements "$APP"
  fi
else
  echo "    临时签名（ad-hoc；未找到 Developer ID / 本地稳定证书）"
  codesign --force --sign - --entitlements Resources/Myna.entitlements "$APP" 2>/dev/null || \
  codesign --force --sign - "$APP"
fi

# 原子替换（同一文件系统内 rename）；正在运行的旧进程继续使用旧 inode。
OLD_APP="$HOME/Applications/.Myna-old.app"
rm -rf "$OLD_APP"
if [ -d "$FINAL_APP" ]; then
  mv "$FINAL_APP" "$OLD_APP"
fi
mv "$APP" "$FINAL_APP"
rm -rf "$OLD_APP"

echo "==> 初始化配置 ~/.config/myna/config.json"
mkdir -p "$HOME/.config/myna"
CONFIG="$HOME/.config/myna/config.json"
if [ ! -f "$CONFIG" ]; then
  cp config.example.json "$CONFIG"
  echo "⚠️  请打开 App「设置 → 模型」填入 API Key（或先 export DEEPSEEK_API_KEY 再运行本脚本）"
fi
chmod 600 "$CONFIG" 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
ln -sf "$FINAL_APP/Contents/MacOS/Myna" "$HOME/.local/bin/myna"

echo ""
echo "✅ 完成"
echo "  App:    $FINAL_APP"
echo "  CLI:    $HOME/.local/bin/myna"
echo "  配置:   $HOME/.config/myna/config.json"
