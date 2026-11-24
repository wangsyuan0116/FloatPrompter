#!/bin/zsh
# 編譯 FloatPrompter
#   ./build.sh          編譯並安裝到 ~/Applications（自己用）
#   ./build.sh release  產生 dist/FloatPrompter.zip（Apple 晶片 + Intel 通用版，給 GitHub Release 用）
set -e
cd "$(dirname "$0")"
# Xcode 授權沒同意時也能編譯
[[ -d /Library/Developer/CommandLineTools ]] && export DEVELOPER_DIR=/Library/Developer/CommandLineTools

make_app() {   # $1 = .app 路徑, 其餘 = swiftc 額外參數
  local APP="$1"; shift
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp Info.plist "$APP/Contents/Info.plist"
  [[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  "$@"
  codesign --force --deep --sign - "$APP"
}

if [[ "$1" == "release" ]]; then
  BUILD=build; APP="$BUILD/FloatPrompter.app"; mkdir -p "$BUILD" dist
  swiftc -O -swift-version 5 -target arm64-apple-macos26.0 main.swift -o "$BUILD/FloatPrompter-arm64"
  swiftc -O -swift-version 5 -target x86_64-apple-macos26.0 main.swift -o "$BUILD/FloatPrompter-x86_64"
  make_app "$APP" lipo -create "$BUILD/FloatPrompter-arm64" "$BUILD/FloatPrompter-x86_64" -output "$APP/Contents/MacOS/FloatPrompter"
  rm -f dist/FloatPrompter.zip
  ditto -c -k --sequesterRsrc --keepParent "$APP" dist/FloatPrompter.zip
  echo "✅ 發佈檔：$(pwd)/dist/FloatPrompter.zip"
else
  APP="$HOME/Applications/FloatPrompter.app"
  make_app "$APP" swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/FloatPrompter"
  echo "✅ 已安裝：$APP"
fi
