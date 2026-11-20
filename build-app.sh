#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
cd "$ROOT"

APP="$ROOT/dist/简易PDF导出工具.app"
MODULE_CACHE="$ROOT/.build/module-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
clang -fobjc-arc -fmodules -mmacosx-version-min=14.0 \
  -framework Cocoa -framework Quartz -framework CoreText \
  "$ROOT/Sources/main.m" -o "$APP/Contents/MacOS/SimplePDFExporter"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/convert-word.js" "$APP/Contents/Resources/convert-word.js"
/usr/bin/osascript -l JavaScript "$ROOT/Resources/convert-word.js"
codesign --force --deep --sign - "$APP"
"$APP/Contents/MacOS/SimplePDFExporter" --self-test
FIXTURE_OUTPUT="$ROOT/Tests/fixture.pdf"
rm -f "$FIXTURE_OUTPUT"
"$APP/Contents/MacOS/SimplePDFExporter" --convert "$ROOT/Tests/fixture.txt"
test -s "$FIXTURE_OUTPUT"
rm -f "$FIXTURE_OUTPUT"
echo "$APP"
