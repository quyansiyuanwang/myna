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
# DMG 卷图标
if [ -f Resources/Myna.icns ]; then
  cp Resources/Myna.icns "$STAGE/.VolumeIcon.icns"
fi

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null

# 挂载并设置卷自定义图标
if [ -f Resources/Myna.icns ]; then
  MNT="$(mktemp -d)"
  if hdiutil attach "$OUT" -nobrowse -mountpoint "$MNT" >/dev/null 2>&1; then
    SetFile -a C "$MNT" 2>/dev/null || true
    hdiutil detach "$MNT" >/dev/null 2>&1 || true
  fi
  rmdir "$MNT" 2>/dev/null || true
fi
echo "DMG: $OUT"
