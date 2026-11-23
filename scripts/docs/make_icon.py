"""make_icon.py — 產生 App 圖示的原始圖片（assets/AppIcon.iconset/*.png）。

白話說明：畫出「膠捲一格一格往前移動＋120」的圖示，存成 macOS 需要的各種尺寸。
編譯時 scripts/build.sh 會用 iconutil 把它們組成 .icns。

用法（開發用，需要 Python 和 Pillow）：
  python3 scripts/docs/make_icon.py assets/AppIcon.iconset
"""
import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter
S = 1024
def font(sz):
    for f in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf","/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"]:
        if os.path.exists(f): return ImageFont.truetype(f, sz)
    return ImageFont.load_default(size=sz)
img = Image.new("RGBA", (S, S), (0,0,0,0))
# rounded square background with vertical gradient (macOS icon grid: ~824px body)
m = 100; body = S - 2*m
grad = Image.new("RGBA", (body, body))
gd = ImageDraw.Draw(grad)
top, bot = (40, 30, 110), (0, 170, 210)
for y in range(body):
    t = y / body
    c = tuple(int(top[i]*(1-t)+bot[i]*t) for i in range(3)) + (255,)
    gd.line([(0,y),(body,y)], fill=c)
mask = Image.new("L", (body, body), 0)
ImageDraw.Draw(mask).rounded_rectangle([0,0,body-1,body-1], radius=185, fill=255)
shadow = Image.new("RGBA", (S,S), (0,0,0,0))
ImageDraw.Draw(shadow).rounded_rectangle([m, m+14, m+body, m+body+14], radius=185, fill=(0,0,0,110))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
img.alpha_composite(shadow)
img.paste(grad, (m, m), mask)
d = ImageDraw.Draw(img)
# motion trail: four frames stepping right, fading in
fw, fh = 330, 250
y0 = 300
for i, alpha in enumerate([55, 95, 150, 255]):
    x0 = 190 + i*95
    layer = Image.new("RGBA", (S,S), (0,0,0,0))
    ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle([x0, y0, x0+fw, y0+fh], radius=28, fill=(255,255,255,alpha))
    # film sprocket holes
    for k in (range(5) if i == 3 else []):
        hx = x0 + 30 + k*62
        ld.rounded_rectangle([hx, y0+16, hx+30, y0+40], radius=6, fill=(40,30,110,alpha))
        ld.rounded_rectangle([hx, y0+fh-40, hx+30, y0+fh-16], radius=6, fill=(40,30,110,alpha))
    img.alpha_composite(layer)
# play triangle on the front frame
fx = 190 + 3*95
cx, cy = fx + fw//2, y0 + fh//2
d.polygon([(cx-45, cy-55), (cx-45, cy+55), (cx+60, cy)], fill=(0,150,200,255))
# "120" label
f = font(230)
txt = "120"
w = d.textlength(txt, font=f)
d.text(((S-w)/2, 590), txt, font=f, fill=(255,255,255,255))
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for base in [16,32,128,256,512]:
    for scale in [1,2]:
        px = base*scale
        name = f"icon_{base}x{base}{'@2x' if scale==2 else ''}.png"
        img.resize((px,px), Image.LANCZOS).save(os.path.join(out, name))
print("ok")
