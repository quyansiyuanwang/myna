#!/bin/bash
# 构建 → Developer ID 签名 → 公证 → 装订 → 打包（zip + dmg + 校验和）
#
# 用法:
#   ./release.sh 0.5.0
#
# 前置条件（见 docs/SIGNING.md）:
#   1. 钥匙串中已安装 "Developer ID Application" 证书
#   2. 已用 notarytool store-credentials 存好公证凭据
#
# 环境变量（可选）:
#   MYNA_SIGN_IDENTITY   指定签名身份（默认自动查找 Developer ID Application）
#   MYNA_NOTARY_PROFILE  notarytool 凭据 profile 名（默认 "Myna"）
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "用法: ./release.sh <version>   例如 ./release.sh 0.5.0" >&2
  exit 1
fi

IDENTITY="${MYNA_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.+)".*/\1/' || true)
fi
if [ -z "$IDENTITY" ]; then
  echo "错误：未找到 'Developer ID Application' 证书。" >&2
  echo "请参考 docs/SIGNING.md 获取并安装证书后重试。" >&2
  exit 1
fi

PROFILE="${MYNA_NOTARY_PROFILE:-Myna}"
APP="dist/Myna.app"
ZIP="dist/Myna-v${VERSION}.zip"
DMG="dist/Myna-v${VERSION}.dmg"

echo "==> 1/5 构建 + Developer ID 签名 + 打包"
MYNA_SIGN_IDENTITY="$IDENTITY" scripts/package.sh "$VERSION"

echo "==> 2/5 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags" || true

echo "==> 3/5 公证并装订 app（zip）"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 4/5 公证并装订 dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> 5/5 重新生成校验和"
( cd dist && shasum -a 256 "Myna-v${VERSION}.zip" "Myna-v${VERSION}.dmg" > SHA256SUMS )

echo ""
echo "✅ 发布物已就绪"
echo "   $ZIP"
echo "   $DMG"
echo "   dist/SHA256SUMS"
echo "   签名身份: $IDENTITY"
