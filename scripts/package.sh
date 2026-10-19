#!/bin/bash
# 构建 Myna.app 并产出 dist/ 下的发布物：zip、dmg、SHA256SUMS
#
# 用法:
#   scripts/package.sh <version> [--universal]
#
# 环境变量:
#   MYNA_SIGN_IDENTITY  指定签名身份（默认自动查找 Developer ID Application，找不到则 ad-hoc）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: scripts/package.sh <version> [--universal]}"
UNIVERSAL="${2:-}"

APP="dist/Myna.app"
mkdir -p dist
rm -rf "$APP"

if [ "$UNIVERSAL" = "--universal" ]; then
  echo "==> 构建通用二进制（arm64 + x86_64）"
  swift build -c release --arch arm64 -Xswiftc -warnings-as-errors
  swift build -c release --arch x86_64 -Xswiftc -warnings-as-errors
  lipo -create -output "dist/Myna.bin" \
    .build/arm64-apple-macosx/release/Myna \
    .build/x86_64-apple-macosx/release/Myna
  BIN="dist/Myna.bin"
else
  echo "==> 构建本机架构"
  swift build -c release -Xswiftc -warnings-as-errors
  BIN="$(swift build -c release --show-bin-path)/Myna"
fi

echo "==> 组装 $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Myna"
# 去除调试符号：通用二进制可从 ~12.6 MB 降到 ~6.1 MB（必须在签名前执行，
# strip 会使已有签名失效）。`-x` 只删本地符号，保留导出符号，不影响运行。
if command -v strip >/dev/null 2>&1; then
  BEFORE=$(stat -f%z "$APP/Contents/MacOS/Myna")
  strip -x "$APP/Contents/MacOS/Myna" 2>/dev/null || true
  AFTER=$(stat -f%z "$APP/Contents/MacOS/Myna")
  echo "    strip: $(echo "$BEFORE $AFTER" | awk '{printf "%.1f MB -> %.1f MB", $1/1048576, $2/1048576}')"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 写入真实版本号：Info.plist 里的占位值是 1.0，若不替换，更新检查会误判「已是最新」
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist" 2>/dev/null || true
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist" 2>/dev/null || true
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
    | sed -E 's/.*"(.+)".*/\1/' || true)
fi
if [ -n "$IDENTITY" ]; then
  echo "    Developer ID: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" --entitlements Resources/Myna.entitlements "$APP"
else
  echo "    ad-hoc"
  codesign --force --sign - --entitlements Resources/Myna.entitlements "$APP" 2>/dev/null || \
  codesign --force --sign - "$APP"
fi

echo "==> 打包"
ZIP="dist/Myna-v${VERSION}.zip"
DMG="dist/Myna-v${VERSION}.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"
scripts/make-dmg.sh "$APP" "$DMG"

echo "==> 校验和"
( cd dist && shasum -a 256 "Myna-v${VERSION}.zip" "Myna-v${VERSION}.dmg" > SHA256SUMS )

rm -f "dist/Myna.bin"
ls -lh dist/
