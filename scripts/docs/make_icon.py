"""make_icon.py — 產生 App 圖示的原始圖片（assets/AppIcon.iconset/*.png）。

白話說明：圖示是「膠捲（播放鍵）＋快轉箭頭＋FPS」，代表把影片的幀數加速、變順。
背景是紫到橘的漸層。會存成 macOS 需要的各種尺寸，編譯時 scripts/build.sh 會用 iconutil 把它們組成 .icns。

重要（macOS 26 以後）：圖示的外框一定要「乖乖待在 Apple 規定的圓角方形（squircle）裡面」。
只要有任何像素超出去（例如陰影），macOS 就會把整個圖示縮小、放進一個灰色的框裡（俗稱 squircle jail）。
所以這裡：
  - 不畫陰影；
  - 外框用「超橢圓」（superellipse，指數 5）畫，形狀接近 Apple 的連續圓角；
  - 比 Apple 的標準範圍（1024 畫布中央 824×824）每邊再往內縮 5 像素，確保不會超出。

用法（開發用，需要 Python 和 Pillow）：
  python3 scripts/docs/make_icon.py assets/AppIcon.iconset
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

S = 1024
TOP, BOTTOM = (90, 20, 120), (240, 90, 60)   # 紫 → 橘


def bold_font(size):
    for f in ["/System/Library/Fonts/SFNS.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"]:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default(size=size)


def squircle_mask(supersample=4):
    """超橢圓遮罩：|x/a|^5 + |y/a|^5 <= 1，a＝412−5（每邊內縮 5 像素）。先放大 4 倍畫再縮小，邊緣才平滑。"""
    big = S * supersample
    a = (412 - 5) * supersample
    c = big / 2
    n = 5.0
    mask = Image.new("L", (big, big), 0)
    px = mask.load()
    for yy in range(big):
        dy = abs((yy + 0.5 - c) / a)
        if dy > 1:
            continue
        # 這一列在超橢圓內的 x 範圍
        dx = (1 - dy ** n) ** (1 / n)
        x0 = int(c - dx * a)
        x1 = int(c + dx * a)
        for xx in range(max(x0, 0), min(x1, big)):
            px[xx, yy] = 255
    return mask.resize((S, S), Image.LANCZOS)


def make():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # 漸層底，用超橢圓遮罩裁成圓角方形（不畫陰影，見檔案開頭說明）
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = min(max((y - 100) / 824, 0), 1)
        gd.line([(0, y), (S, y)], fill=tuple(int(TOP[i] * (1 - t) + BOTTOM[i] * t) for i in range(3)) + (255,))
    img.paste(grad, (0, 0), squircle_mask())

    # 前景（膠捲、播放鍵、文字）都畫在獨立的一層，最後再疊上去，圖示裡面才不會出現半透明的洞
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    # 膠捲（白色，上下有齒孔）＋橘色播放鍵
    x, y, w, h = 170, 330, 400, 330
    d.rounded_rectangle([x, y, x + w, y + h], radius=24, fill=(255, 255, 255, 255))
    hole_w = w // 8
    for k in range(4):
        hx = x + hole_w // 2 + k * (w // 4) + 8
        d.rounded_rectangle([hx, y + 14, hx + hole_w, y + 36], radius=5, fill=TOP + (255,))
        d.rounded_rectangle([hx, y + h - 36, hx + hole_w, y + h - 14], radius=5, fill=TOP + (255,))
    d.polygon([(300, 410), (300, 580), (440, 495)], fill=BOTTOM + (255,))
    # 快轉箭頭（兩個 >，前面那個比較淡）。
    # 淡的那個要畫在另一層再「疊」上去：直接畫半透明會在圖示上挖出半透明的洞，macOS 26 可能因此把圖示關進灰框。
    for i, ax in enumerate([600, 700]):
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(
            [(ax, 360), (ax + 120, 495), (ax, 630), (ax + 40, 630), (ax + 160, 495), (ax + 40, 360)],
            fill=(255, 255, 255, 255 if i else 170))
        img.alpha_composite(layer)
    # FPS 字樣
    d.text((S / 2, 770), "FPS", font=bold_font(120), fill=(255, 255, 255, 255), anchor="mm")
    img.alpha_composite(fg)
    return img


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/AppIcon.iconset"
    os.makedirs(out, exist_ok=True)
    icon = make()
    for base in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
    print("已產生", out)
