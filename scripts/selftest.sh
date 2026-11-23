#!/bin/bash
# selftest.sh — 用附帶的測試影片（test/sample_30fps.mp4：4 秒、1080p、30 FPS、有聲音）
# 實際轉換，檢查結果的幀率是不是真的正確。安裝時會自動執行；不通過就不會安裝。
#
# 分別轉成 60、120、144 FPS，以及用「快速」補幀方式再轉一次 120，每一種都檢查四件事：
#   1. 畫面數符合預期（例如 30 → 120 約 4 倍、30 → 144 約 4.8 倍）
#   2. 實際幀率（畫面數 ÷ 長度）約等於目標
#   3. 聲音還在
#   4. 有「用原本的幀率正常播放」標記（iPhone「照片」才不會當成慢動作）
# 另外試轉一支 VP9 格式的影片（test/sample_vp9.mp4，網站下載的影片常見這種格式），
# 只顯示「讀得了／讀不了」，不影響安裝（有些 Mac 可能本來就不支援）。
# 最後印出每一種花了幾秒（第一次轉檔包含 AI 引擎載入的時間，所以先轉 60 當暖身）。

cd "$(dirname "$0")/.."
BIN="build/frame-booster"
# 安裝時畫面輸出會同時寫進紀錄檔（tee）。設這個變數，讓進度條直接畫在終端機視窗上，紀錄檔不會被塞爆。
export FRAMEBOOSTER_TTY_PROGRESS=1
IN="test/sample_30fps.mp4"

[ -x "$BIN" ] || { echo "❌ 找不到 ${BIN}，請先編譯（scripts/build.sh）"; exit 1; }

field() { sed -n "s/.*$1=\([0-9.]*\).*/\1/p" <<<"$2"; }

before=$("$BIN" --info "$IN") || { echo "❌ 讀不到測試影片"; exit 1; }
echo "原始：$before"
fin=$(field frames "$before")
fpsin=$(field measured "$before")
ok=1

now() { perl -MTime::HiRes=time -e 'printf "%.1f", time' 2>/dev/null || date +%s; }
SUMMARY=""

# 轉成指定的幀率，檢查結果。用法：check <目標幀率> [fast]
check() {
    local target=$1 mode=${2:-}
    local out="build/selftest_${target}fps${mode:+_$mode}.mov"
    local label="${target} FPS・$([ "$mode" = fast ] && echo 快速 || echo 精細)"
    rm -f "$out"
    echo ""
    echo "── 測試：30 → ${label} ──"
    local start; start=$(now)
    if ! "$BIN" "$IN" --fps "$target" ${mode:+--fast} -o "$out"; then
        echo "❌ 轉檔失敗"; ok=0; return
    fi
    local took; took=$(awk -v a="$start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
    echo "轉檔花了 ${took} 秒"
    SUMMARY="${SUMMARY}  ${label}：${took} 秒"$'\n'
    local after; after=$("$BIN" --info "$out") || { echo "❌ 讀不到轉好的影片"; ok=0; return; }
    echo "結果：$after"
    local fout fps audio full expected
    fout=$(field frames "$after")
    fps=$(field measured "$after")
    audio=$(field audioTracks "$after")
    full=$(field fullFrameRate "$after")
    # 預期畫面數 = 原本畫面數 × 目標幀率 ÷ 原本幀率（四捨五入）
    expected=$(awk -v n="$fin" -v t="$target" -v f="$fpsin" 'BEGIN { printf "%d", n * t / f + 0.5 }')
    if [ -z "$fout" ] || [ "$fout" -lt $(( expected - 3 )) ] || [ "$fout" -gt $(( expected + 3 )) ]; then
        echo "❌ 畫面數不對：預期約 $expected 張，實際 ${fout:-?} 張"; ok=0
    else
        echo "✔ 畫面數：$fin → ${fout}（預期約 ${expected}）"
    fi
    if ! awk -v f="${fps:-0}" -v t="$target" 'BEGIN { exit !(f >= t - 2 && f <= t + 2) }'; then
        echo "❌ 幀率不對：預期約 ${target}，實際 ${fps:-?}"; ok=0
    else
        echo "✔ 幀率：約 $fps FPS"
    fi
    if [ "${audio:-0}" -lt 1 ]; then
        echo "❌ 聲音不見了"; ok=0
    else
        echo "✔ 聲音：保留"
    fi
    if [ "${full:-}" != "1" ]; then
        echo "❌ 沒有「正常速度播放」標記（iPhone 可能會當成慢動作播放）"; ok=0
    else
        echo "✔ 播放：標記為正常速度（不會被當成慢動作）"
    fi
}

check 60          # 2 倍（也當作 AI 引擎的暖身）
check 120         # 預設：剛好 4 倍
check 144         # 4.8 倍：不是整數倍，檢查「依時間對齊」的算法
check 120 fast    # 補幀方式「快速」，和上面的 120「精細」比較速度

# VP9 影片：只報告結果，不影響安裝
echo ""
echo "── 測試：VP9 格式的影片（網站下載的 .mp4 常見）──"
VP9OUT="build/selftest_vp9_60fps.mov"
rm -f "$VP9OUT"
if "$BIN" "test/sample_vp9.mp4" --fps 60 -o "$VP9OUT" >/dev/null 2>&1 && vp9info=$("$BIN" --info "$VP9OUT"); then
    echo "✔ VP9：可以讀取並轉檔（結果：$(field frames "$vp9info") 張畫面）"
else
    echo "⚠️ VP9：這台 Mac 讀不了 VP9 影片（不影響安裝；這種影片需要先用 HandBrake 轉成 H.264／H.265）"
fi

echo ""
echo "速度參考（4 秒 1080p 測試影片，這台 Mac）："
printf "%s" "$SUMMARY"

echo ""
[ $ok = 1 ] && echo "✅ 自我測試全部通過（測試結果在 build/selftest_*fps.mov）" && exit 0
echo "❌ 自我測試有項目沒通過"
exit 1
