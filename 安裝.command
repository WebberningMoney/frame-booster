#!/bin/bash
# 安裝.command — 雙擊這個檔案就會：
#   1. 檢查這台 Mac 能不能用（Apple 晶片＋macOS 15.4 以上）
#   2. 把原始碼編譯成程式（scripts/build.sh）
#   3. 用測試影片實際轉成 120、60、144 FPS，確認結果正確（scripts/selftest.sh）
#   4. 測試通過才把 FrameBooster 放進「應用程式」資料夾，並打開它
# 過程會記錄在 build/install_log.txt，出問題時可以把它提供給開發者。
# 更新到新版時，再雙擊一次即可（會取代舊版的 App；你轉好的影片不受影響）。

cd "$(dirname "$0")" || exit 1
mkdir -p build
LOG="$PWD/build/install_log.txt"
exec > >(tee "$LOG") 2>&1

fail() {
    echo ""
    echo "❌ $1"
    echo "   安裝紀錄：$LOG"
    echo ""
    read -r -p "按 Enter 關閉這個視窗…" _
    exit 1
}

echo "=== FrameBooster 安裝 $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "macOS $(sw_vers -productVersion)（$(uname -m)）"

# ---- 1. 檢查電腦 ----
[ "$(uname -m)" = "arm64" ] || fail "需要 Apple 晶片（M1 以後）的 Mac。Intel Mac 沒有 Apple 的 AI 補幀功能。"
ver=$(sw_vers -productVersion)
lowest=$(printf '%s\n%s\n' "15.4" "$ver" | sort -V | head -1)
[ "$lowest" = "15.4" ] || fail "需要 macOS 15.4 以上（你的是 $ver）。請先到「系統設定 → 一般 → 軟體更新」更新。"

# ---- 2. 編譯 ----
echo ""
bash scripts/build.sh || fail "編譯失敗。請把上面的錯誤訊息（或安裝紀錄）提供給開發者。"

# ---- 3. 自我測試 ----
echo ""
echo "▶ 用測試影片實際轉換三次（120、60、144 FPS），確認結果正確..."
bash scripts/selftest.sh || fail "自我測試沒有通過，所以沒有安裝。請把安裝紀錄提供給開發者。"

# ---- 4. 放進「應用程式」 ----
DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi
TARGET="$DEST/FrameBooster.app"
pkill -x FrameBooster 2>/dev/null && sleep 1
rm -rf "$TARGET"
ditto build/FrameBooster.app "$TARGET" || fail "無法複製到 $DEST。"

echo ""
echo "✅ 安裝完成！FrameBooster 已放在：$TARGET"
echo "   以後從「應用程式」或 Launchpad 打開它，把影片拖進視窗就會開始轉。"
echo "   轉好的影片會放在原影片旁邊，檔名加上「_120fps」。"
open "$TARGET"
echo ""
read -r -p "按 Enter 關閉這個視窗…" _
