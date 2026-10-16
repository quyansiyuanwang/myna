#!/bin/bash
# 由 .app 生成 DMG（内含指向 /Applications 的快捷方式）
#
# 用法: scripts/make-dmg.sh <App路径> <输出.dmg> [卷名]
set -euo pipefail

APP="${1:?用法: make-dmg.sh <App路径> <输出.dmg> [卷名]}"
OUT="${2:?用法: make-dmg.sh <App路径> <输出.dmg> [卷名]}"
VOL="${3:-Myna}"

[ -d "$APP" ] || { echo "错误：找不到 $APP" >&2; exit 1; }
APP_NAME="$(basename "$APP")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "DMG: $OUT"
