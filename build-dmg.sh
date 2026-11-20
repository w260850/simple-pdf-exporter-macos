#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/dist/简易PDF导出工具.app"
DMG="$ROOT/dist/简易PDF导出工具-1.1.dmg"
STAGING="$(mktemp -d "$ROOT/.build/dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

"$ROOT/build-app.sh"
ditto "$APP" "$STAGING/简易PDF导出工具.app"
cp "$ROOT/安装说明.txt" "$STAGING/安装说明.txt"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "简易PDF导出工具 1.1" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$DMG"

hdiutil verify "$DMG"
shasum -a 256 "$DMG"
echo "$DMG"
