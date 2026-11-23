#!/bin/bash
# 解除安裝.command — 從「應用程式」移除 FrameBooster。
# FrameBooster 不會在電腦其他地方存資料或設定，所以移除 App 就乾淨了。
# 你轉好的影片（*_120fps.mov）不會被刪除。

echo "=== 移除 FrameBooster ==="
found=()
for app in "/Applications/FrameBooster.app" "$HOME/Applications/FrameBooster.app"; do
    [ -d "$app" ] && found+=("$app")
done

if [ ${#found[@]} -eq 0 ]; then
    echo "沒有找到已安裝的 FrameBooster。"
    read -r -p "按 Enter 關閉這個視窗…" _
    exit 0
fi

echo "將會移除："
printf '  %s\n' "${found[@]}"
echo "（你轉好的影片不會被刪除）"
read -r -p "確定要移除嗎？輸入 y 再按 Enter：" ans
if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    echo "已取消，沒有移除任何東西。"
    read -r -p "按 Enter 關閉這個視窗…" _
    exit 0
fi

pkill -x FrameBooster 2>/dev/null && sleep 1
for app in "${found[@]}"; do
    rm -rf "$app" && echo "已移除：$app"
done
echo ""
echo "✅ 完成。最後把 frame-booster 資料夾丟到垃圾桶即可。"
read -r -p "按 Enter 關閉這個視窗…" _
