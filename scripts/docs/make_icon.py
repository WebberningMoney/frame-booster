"""make_icon.py — 產生 App 圖示的原始圖片（assets/AppIcon.iconset/*.png）。

白話說明：圖示是「膠捲（播放鍵）＋快轉箭頭＋FPS」，代表把影片的幀數加速、變順。
背景是紫到橘的漸層。會存成 macOS 需要的各種尺寸，編譯時 scripts/build.sh 會用 iconutil 把它們組成 .icns。

用法（開發用，需要 Python 和 Pillow）：
  python3 scripts/docs/make_icon.py assets/AppIcon.iconset
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024
TOP, BOTTOM = (90, 20, 120), (240, 90, 60)   # 紫 → 橘


def bold_font(size):
    for f in ["/System/Library/Fonts/SFNS.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"]:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default(size=size)


def make():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # 圓角方形底（依 macOS 圖示格線：四周留約 10%）
    m = 100
    body = S - 2 * m
    grad = Image.new("RGBA", (body, body))
    gd = ImageDraw.Draw(grad)
    for y in range(body):
        t = y / body
        gd.line([(0, y), (body, y)], fill=tuple(int(TOP[i] * (1 - t) + BOTTOM[i] * t) for i in range(3)) + (255,))
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=185, fill=255)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([m, m + 14, m + body, m + body + 14], radius=185, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    img.paste(grad, (m, m), mask)

    d = ImageDraw.Draw(img)
    # 膠捲（白色，上下有齒孔）＋橘色播放鍵
    x, y, w, h = 170, 330, 400, 330
    d.rounded_rectangle([x, y, x + w, y + h], radius=24, fill=(255, 255, 255, 255))
    hole_w = w // 8
    for k in range(4):
        hx = x + hole_w // 2 + k * (w // 4) + 8
        d.rounded_rectangle([hx, y + 14, hx + hole_w, y + 36], radius=5, fill=TOP + (255,))
        d.rounded_rectangle([hx, y + h - 36, hx + hole_w, y + h - 14], radius=5, fill=TOP + (255,))
    d.polygon([(300, 410), (300, 580), (440, 495)], fill=BOTTOM + (255,))
    # 快轉箭頭（兩個 >，後面那個比較淡）
    for i, ax in enumerate([600, 700]):
        d.polygon([(ax, 360), (ax + 120, 495), (ax, 630), (ax + 40, 630), (ax + 160, 495), (ax + 40, 360)],
                  fill=(255, 255, 255, 255 if i else 170))
    # FPS 字樣
    d.text((S / 2, 770), "FPS", font=bold_font(120), fill=(255, 255, 255, 240), anchor="mm")
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
