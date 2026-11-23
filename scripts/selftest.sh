#!/bin/bash
# selftest.sh — 用附帶的測試影片（test/sample_30fps.mp4：4 秒、1080p、30 FPS、有聲音）
# 實際轉一次，檢查結果是不是真的變成 120 FPS。安裝時會自動執行；不通過就不會安裝。
#
# 檢查三件事：
#   1. 畫面數約為原本的 4 倍（30 → 120）
#   2. 實際幀率（畫面數 ÷ 長度）約為 120
#   3. 聲音還在

cd "$(dirname "$0")/.."
BIN="build/frame-booster"
IN="test/sample_30fps.mp4"
OUT="build/selftest_120fps.mov"

[ -x "$BIN" ] || { echo "❌ 找不到 $BIN，請先編譯（scripts/build.sh）"; exit 1; }
rm -f "$OUT"

field() { sed -n "s/.*$1=\([0-9.]*\).*/\1/p" <<<"$2"; }

before=$("$BIN" --info "$IN") || { echo "❌ 讀不到測試影片"; exit 1; }
echo "原始：$before"

start=$(date +%s)
if ! "$BIN" "$IN" -o "$OUT"; then
    echo "❌ 測試轉檔失敗"
    exit 1
fi
echo "轉檔花了 $(( $(date +%s) - start )) 秒"

after=$("$BIN" --info "$OUT") || { echo "❌ 讀不到轉好的影片"; exit 1; }
echo "結果：$after"

fin=$(field frames "$before")
fout=$(field frames "$after")
fps=$(field measured "$after")
audio=$(field audioTracks "$after")
ok=1

expected=$(( fin * 4 ))
if [ -z "$fout" ] || [ "$fout" -lt $(( expected - 4 )) ] || [ "$fout" -gt $(( expected + 4 )) ]; then
    echo "❌ 畫面數不對：預期約 $expected 張，實際 ${fout:-?} 張"; ok=0
else
    echo "✔ 畫面數：$fin → $fout（約 4 倍）"
fi
if ! awk -v f="${fps:-0}" 'BEGIN { exit !(f >= 118 && f <= 122) }'; then
    echo "❌ 幀率不對：預期約 120，實際 ${fps:-?}"; ok=0
else
    echo "✔ 幀率：約 $fps FPS"
fi
if [ "${audio:-0}" -lt 1 ]; then
    echo "❌ 聲音不見了"; ok=0
else
    echo "✔ 聲音：保留"
fi

[ $ok = 1 ] && echo "✅ 自我測試通過（測試結果：$OUT）" && exit 0
exit 1
