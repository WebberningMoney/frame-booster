#!/bin/bash
# selftest.sh — 用附帶的測試影片（test/sample_30fps.mp4：4 秒、1080p、30 FPS、有聲音）
# 實際轉換，檢查結果的幀率是不是真的正確。安裝時會自動執行；不通過就不會安裝。
#
# 分別轉成 120、60、144 FPS，每一種都檢查三件事：
#   1. 畫面數符合預期（例如 30 → 120 約 4 倍、30 → 144 約 4.8 倍）
#   2. 實際幀率（畫面數 ÷ 長度）約等於目標
#   3. 聲音還在

cd "$(dirname "$0")/.."
BIN="build/frame-booster"
IN="test/sample_30fps.mp4"

[ -x "$BIN" ] || { echo "❌ 找不到 $BIN，請先編譯（scripts/build.sh）"; exit 1; }

field() { sed -n "s/.*$1=\([0-9.]*\).*/\1/p" <<<"$2"; }

before=$("$BIN" --info "$IN") || { echo "❌ 讀不到測試影片"; exit 1; }
echo "原始：$before"
fin=$(field frames "$before")
fpsin=$(field measured "$before")
ok=1

# 轉成指定的幀率，檢查結果。用法：check <目標幀率>
check() {
    local target=$1
    local out="build/selftest_${target}fps.mov"
    rm -f "$out"
    echo ""
    echo "── 測試：30 → ${target} FPS ──"
    local start; start=$(date +%s)
    if ! "$BIN" "$IN" --fps "$target" -o "$out"; then
        echo "❌ 轉檔失敗"; ok=0; return
    fi
    echo "轉檔花了 $(( $(date +%s) - start )) 秒"
    local after; after=$("$BIN" --info "$out") || { echo "❌ 讀不到轉好的影片"; ok=0; return; }
    echo "結果：$after"
    local fout fps audio expected
    fout=$(field frames "$after")
    fps=$(field measured "$after")
    audio=$(field audioTracks "$after")
    # 預期畫面數 = 原本畫面數 × 目標幀率 ÷ 原本幀率（四捨五入）
    expected=$(awk -v n="$fin" -v t="$target" -v f="$fpsin" 'BEGIN { printf "%d", n * t / f + 0.5 }')
    if [ -z "$fout" ] || [ "$fout" -lt $(( expected - 3 )) ] || [ "$fout" -gt $(( expected + 3 )) ]; then
        echo "❌ 畫面數不對：預期約 $expected 張，實際 ${fout:-?} 張"; ok=0
    else
        echo "✔ 畫面數：$fin → $fout（預期約 $expected）"
    fi
    if ! awk -v f="${fps:-0}" -v t="$target" 'BEGIN { exit !(f >= t - 2 && f <= t + 2) }'; then
        echo "❌ 幀率不對：預期約 $target，實際 ${fps:-?}"; ok=0
    else
        echo "✔ 幀率：約 $fps FPS"
    fi
    if [ "${audio:-0}" -lt 1 ]; then
        echo "❌ 聲音不見了"; ok=0
    else
        echo "✔ 聲音：保留"
    fi
}

check 120   # 預設：剛好 4 倍
check 60    # 2 倍
check 144   # 4.8 倍：不是整數倍，檢查「依時間對齊」的算法

echo ""
[ $ok = 1 ] && echo "✅ 自我測試全部通過（測試結果在 build/selftest_*fps.mov）" && exit 0
echo "❌ 自我測試有項目沒通過"
exit 1
