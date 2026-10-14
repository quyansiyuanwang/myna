#!/bin/bash
# 构建 → Developer ID 签名 → 公证 → 装订 → 打包发布物
#
# 用法:
#   ./release.sh 0.3.2
#
# 前置条件（见 docs/SIGNING.md）:
#   1. 钥匙串中已安装 "Developer ID Application" 证书
#   2. 已用 notarytool store-credentials 存好公证凭据
#
# 环境变量（可选）:
#   AISIRI_SIGN_IDENTITY   指定签名身份（默认自动查找 Developer ID Application）
#   AISIRI_NOTARY_PROFILE  notarytool 凭据 profile 名（默认 "AiSiri"）
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "用法: ./release.sh <version>   例如 ./release.sh 0.3.2" >&2
  exit 1
fi

IDENTITY="${AISIRI_SIGN_IDENTITY:-}"
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

PROFILE="${AISIRI_NOTARY_PROFILE:-AiSiri}"
APP="$HOME/Applications/AiSiri.app"
ZIP="AiSiri-v${VERSION}.zip"

echo "==> 1/6 构建并用 Developer ID 签名"
AISIRI_SIGN_IDENTITY="$IDENTITY" ./build.sh

echo "==> 2/6 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags" || true

echo "==> 3/6 打包（提交公证前）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 4/6 提交公证（等待结果）"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> 5/6 装订公证票据"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> 6/6 重新打包（含装订票据）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "✅ 发布物已就绪: $ZIP"
echo "   签名身份: $IDENTITY"
echo "   公证 profile: $PROFILE"
