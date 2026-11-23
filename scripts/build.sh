#!/bin/bash
# build.sh — 把原始碼編譯成兩個程式，放在 build/ 資料夾：
#   build/frame-booster        命令列版本
#   build/FrameBooster.app     視窗版本（拖放影片用）
#
# 一般使用者不用直接執行它：雙擊「安裝.command」時會自動呼叫。
# 需要 Apple 的「命令列開發者工具」（裡面有 Swift 編譯器），沒有的話會提示安裝。

set -e
cd "$(dirname "$0")/.."

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "❌ 找不到 Swift 編譯器（Apple 的「命令列開發者工具」還沒裝）。"
    echo "   即將跳出安裝視窗，請按「安裝」；裝好（約 5～10 分鐘）後再執行一次安裝。"
    xcode-select --install 2>/dev/null || true
    exit 1
fi

echo "Swift：$(xcrun swiftc --version 2>&1 | head -1)"
echo "SDK：macOS $(xcrun --sdk macosx --show-sdk-version)"

mkdir -p build
FLAGS=(-O -swift-version 5 -target arm64-apple-macos15.4 -sdk "$(xcrun --sdk macosx --show-sdk-path)")

echo "▶ 編譯命令列版本 ..."
xcrun swiftc "${FLAGS[@]}" Sources/Converter.swift Sources/CLI/main.swift -o build/frame-booster

echo "▶ 編譯視窗版本 ..."
APP="build/FrameBooster.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xcrun swiftc "${FLAGS[@]}" -parse-as-library Sources/Converter.swift Sources/App/App.swift \
    -o "$APP/Contents/MacOS/FrameBooster"

# 圖示：把 assets/AppIcon.iconset 裡的圖片組成 macOS 用的 .icns。失敗也不影響使用。
iconutil -c icns assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
    || echo "（圖示建立失敗，App 會使用預設圖示）"

# 簽章：用「本機簽章」（ad-hoc），讓 macOS 願意執行在這台電腦上自己編譯的程式。
codesign --force --sign - build/frame-booster >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "✅ 編譯完成"
