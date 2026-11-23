"""make_mockups.py — 產生 README 用的「示意圖」（docs/images/*.png）。

白話說明：
  App 只能在 Mac 上執行，雲端沙盒拍不到真的截圖，所以先用網頁（HTML／CSS）畫出長得像 App 的畫面，
  再用無頭 Chrome 拍成 PNG。每張圖右上角都有橘色「示意圖」標籤。
  之後在 Mac 上拍到真的截圖時，請直接換掉 docs/images/ 裡的同名檔案。

  畫面文字改了（例如 FPSPresets.swift 的裝置清單），請一起改這裡再重新產生。

用法（開發用，需要 Python、playwright 和 Google Chrome）：
  python3 scripts/docs/make_mockups.py docs/images
"""
import sys, pathlib, asyncio
from playwright.async_api import async_playwright

OUT = pathlib.Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)

CSS = """
* { box-sizing: border-box; }
body { margin: 0; padding: 28px; display: inline-block; background: #d9dde3; font-family: 'Noto Sans CJK TC', 'PingFang TC', -apple-system, sans-serif;
       -webkit-font-smoothing: antialiased; }
.win { width: 720px; background: #f5f5f7; border-radius: 12px; box-shadow: 0 18px 50px rgba(0,0,0,.28), 0 0 0 .5px rgba(0,0,0,.25);
       overflow: hidden; position: relative; }
.titlebar { height: 38px; display: flex; align-items: center; justify-content: center; position: relative;
            background: #ececee; border-bottom: 1px solid #d6d6d8; font-size: 13px; font-weight: 600; color: #333; }
.lights { position: absolute; left: 14px; top: 13px; display: flex; gap: 8px; }
.lights span { width: 12px; height: 12px; border-radius: 50%; display: block; }
.content { padding: 18px; display: flex; flex-direction: column; gap: 13px; min-height: 470px; }
.drop { height: 150px; border: 2px dashed #b9b9be; border-radius: 14px; display: flex; flex-direction: column;
        align-items: center; justify-content: center; gap: 6px; }
.drop.active { border-color: #0a84ff; background: rgba(10,132,255,.07); }
.drop .icon { width: 40px; height: 34px; }
.drop h3 { margin: 0; font-size: 17px; font-weight: 600; color: #1d1d1f; }
.drop p { margin: 0; font-size: 11.5px; color: #86868b; }
.btn { display: inline-block; font-size: 12.5px; padding: 3px 11px; border-radius: 6px; background: #fff; color: #1d1d1f;
       box-shadow: 0 0 0 .5px rgba(0,0,0,.18), 0 1px 1.5px rgba(0,0,0,.12); }
.btn.disabled { color: #b5b5ba; }
.row { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #1d1d1f; }
.spacer { flex: 1; }
.popup { display: inline-flex; align-items: center; gap: 10px; font-size: 12.5px; padding: 3px 6px 3px 10px; border-radius: 6px;
         background: #fff; box-shadow: 0 0 0 .5px rgba(0,0,0,.18), 0 1px 1.5px rgba(0,0,0,.12); }
.chev { width: 16px; height: 18px; border-radius: 4px; background: #0a84ff; color: #fff; font-size: 9px; line-height: 8px;
        display: flex; flex-direction: column; align-items: center; justify-content: center; }
.seg { display: inline-flex; padding: 2px; background: #e3e3e6; border-radius: 7px; font-size: 12.5px; }
.seg span { padding: 2px 16px; border-radius: 5px; color: #1d1d1f; }
.seg span.on { background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.18); }
.hint { flex: 1; display: flex; align-items: center; justify-content: center; color: #86868b; font-size: 13px; }
.list { flex: 1; background: #fff; border-radius: 8px; box-shadow: 0 0 0 .5px rgba(0,0,0,.12); padding: 4px 0; }
.job { display: flex; align-items: center; gap: 12px; padding: 9px 14px; border-bottom: 1px solid #f0f0f2; }
.job:last-child { border-bottom: none; }
.job .st { width: 20px; text-align: center; font-size: 15px; }
.job .main { flex: 1; min-width: 0; }
.job .name { font-size: 13px; color: #1d1d1f; }
.job .sub { font-size: 11px; color: #86868b; margin-top: 3px; }
.bar { height: 5px; border-radius: 3px; background: #e5e5ea; margin-top: 5px; overflow: hidden; }
.bar i { display: block; height: 100%; background: #0a84ff; border-radius: 3px; }
.spin { width: 14px; height: 14px; border-radius: 50%; border: 2px solid #d1d1d6; border-top-color: #6e6e73; display: inline-block; }
.badge { position: absolute; right: 14px; top: 48px; background: rgba(255,149,0,.92); color: #fff; font-size: 12px; font-weight: 700;
         padding: 3px 10px; border-radius: 10px; letter-spacing: 1px; z-index: 9; }
.menu { position: absolute; background: #f6f6f8; border-radius: 8px; padding: 5px;
        box-shadow: 0 10px 30px rgba(0,0,0,.22), 0 0 0 .5px rgba(0,0,0,.2); font-size: 12.5px; z-index: 5; }
.menu div { padding: 4px 10px 4px 24px; border-radius: 4px; position: relative; color: #1d1d1f; white-space: nowrap; }
.menu div.sel::before { content: '✓'; position: absolute; left: 8px; }
.menu div.hl { background: #0a84ff; color: #fff; }
.tip { position: absolute; background: #fbfbfb; border: .5px solid #bdbdbd; box-shadow: 0 4px 12px rgba(0,0,0,.18);
       font-size: 11.5px; line-height: 1.55; color: #222; padding: 7px 10px; width: 380px; border-radius: 4px; z-index: 6; white-space: pre-line; }
.cursor { position: absolute; z-index: 7; }
.muted { color: #86868b; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.disc { color: #1d1d1f; } .tri { color: #6e6e73; font-size: 11px; width: 10px; display: inline-block; }
.adv { display: flex; flex-direction: column; gap: 10px; padding-left: 22px; }
.lbl { width: 64px; display: inline-block; }
.btn.primary { background: #0a84ff; color: #fff; font-weight: 600; padding: 5px 22px; box-shadow: none; }
.btn.primary.off { background: #b9d8fb; color: #f5f9ff; }
.note { font-size: 11.5px; color: #86868b; margin-top: -6px; }
.x { color: #a1a1a6; font-size: 13px; padding: 0 4px; }
.cb { width: 15px; height: 15px; border-radius: 4px; border: 1px solid #b0b0b5; background: #fff; display: inline-flex;
      align-items: center; justify-content: center; font-size: 11px; color: #fff; flex: none; }
.cb.on { background: #0a84ff; border-color: #0a84ff; }
.cb.dis { background: #eeeef0; border-color: #d4d4d8; }
.size { font-size: 10.5px; color: #a1a1a6; margin-top: 2px; }
.selbar { gap: 6px; margin-bottom: -6px; } .btn.sm { font-size: 11px; padding: 1px 8px; }
.tipline { font-size: 10.5px; color: #86868b; margin-left: 4px; }
"""

FILM_ICON = """<svg class="icon" viewBox="0 0 40 34"><g fill="none" stroke="{c}" stroke-width="2.2" stroke-linejoin="round">
<rect x="8" y="2" width="30" height="22" rx="3" opacity=".45"/><rect x="2" y="9" width="30" height="22" rx="3" fill="#f5f5f7"/>
<path d="M14 15v10l8-5z" fill="{c}" stroke="none"/></g></svg>"""

CURSOR = """<svg class="cursor" style="left:{x}px;top:{y}px" width="16" height="22" viewBox="0 0 16 22">
<path d="M1 1v17l4.5-4.2 3 6.7 2.6-1.2-3-6.5H14z" fill="#000" stroke="#fff" stroke-width="1.2"/></svg>"""

def window(inner, overlay="", drop_active=False, advanced=False, outdir=None,
           start="開始轉檔", start_on=False, running=False, note=""):
    c = "#0a84ff" if drop_active else "#8e8e93"
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>
<div class="win" id="win">
  <div class="titlebar"><div class="lights"><span style="background:#ff5f57"></span><span style="background:#febc2e"></span><span style="background:#28c840"></span></div>FrameBooster</div>
  <div class="badge">示意圖</div>
  <div class="content">
    <div class="drop{' active' if drop_active else ''}">{FILM_ICON.format(c=c)}
      <h3>把影片拖到這裡</h3><p>把 30 FPS 的影片補成 60～240 FPS，在高更新率的螢幕上看起來更順</p>
      <span class="btn" style="margin-top:3px">選擇影片…</span></div>
    <div class="row">目標幀率 <span class="popup" id="popup">120 FPS — iPhone 17／Pro、iPad Pro、MacBook Pro <span class="chev">⌃<br>⌄</span></span></div>
    <div class="row">輸出位置 <span class="muted">{outdir or "原影片旁邊"}</span> <span class="btn">選擇資料夾…</span>{' <span class="btn">改回原影片旁邊</span>' if outdir else ''}</div>
    <div class="row disc"><span class="tri">{'▾' if advanced else '▸'}</span> 進階設定</div>
    {ADV if advanced else ''}
    <div class="row"><span class="btn primary {'' if start_on else 'off'}">{start}</span><span class="spacer"></span>
      <span class="btn {'' if running else 'disabled'}">取消轉檔</span><span class="btn {'' if ('✔' in inner or '⏭' in inner) else 'disabled'}">清除已完成</span></div>
    {f'<div class="note">{note}</div>' if note else ''}
    {inner}
  </div>
  {overlay}
</div></body></html>"""

ADV = """<div class="adv">
  <div class="row"><span class="lbl">補幀方式</span><span class="seg"><span class="on">精細</span><span>快速</span></span></div>
  <div class="row"><span class="lbl">輸出畫質</span><span class="seg"><span>高</span><span class="on">標準</span><span>省空間</span></span></div>
</div>"""

EMPTY = '<div class="hint">轉好的影片會放在原影片旁邊，檔名加上「_120fps」。</div>'

pages = {}
def cb(on=True, disabled=False):
    """勾選框"""
    cls = "cb" + (" on" if on else "") + (" dis" if disabled else "")
    return f'<span class="{cls}">{"✓" if on and not disabled else ""}</span>'

SELBAR = """<div class="row selbar"><span class="btn sm">全選</span><span class="btn sm">全不選</span>
  <span class="tipline">小技巧：勾一支後，按住 Shift 再勾另一支，中間整段都會勾起來</span></div>"""

waiting = SELBAR + f"""<div class="list">
 <div class="job">{cb()}<div class="st" style="color:#8e8e93">📥</div><div class="main"><div class="name">旅行_台南.mov</div>
   <div class="sub">等待中（已勾選，按「開始轉檔」後開始）</div>
   <div class="size">原檔 85.2 MB → 預估約 171 MB（120 FPS・標準畫質，實際可能小一些）</div></div><span class="x">✕</span></div>
 <div class="job">{cb()}<div class="st" style="color:#8e8e93">📥</div><div class="main"><div class="name">家人聚餐.mp4</div>
   <div class="sub">等待中（已勾選，按「開始轉檔」後開始）</div>
   <div class="size">原檔 312 MB → 預估約 624 MB（120 FPS・標準畫質，實際可能小一些）</div></div><span class="x">✕</span></div>
 <div class="job">{cb(False)}<div class="st" style="color:#8e8e93">📥</div><div class="main"><div class="name">螢幕錄影.mov</div>
   <div class="sub">等待中（沒有勾選，不會轉）</div>
   <div class="size">原檔 48.6 MB → 預估約 97.1 MB（120 FPS・標準畫質，實際可能小一些）</div></div><span class="x">✕</span></div>
</div>"""
pages["main"] = window(waiting, start="開始轉檔（已勾選 2 支）", start_on=True)

menu_items = [
    ("60 FPS — 一般螢幕、電視、iPhone 17e、MacBook Air", ""),
    ("120 FPS — iPhone 17／Pro、iPad Pro、MacBook Pro", "sel"),
    ("144 FPS — 電競螢幕、電競手機、144Hz 電視", "hl"),
    ("240 FPS — 高階電競螢幕（ASUS ROG、MSI、Samsung Odyssey 等）", ""),
]
tip144 = ("144 FPS：電競螢幕與電競手機常見的規格。165Hz、185Hz 的裝置播 144 FPS 也很順。\n"
          "• 手機：RedMagic 11 Pro（144Hz）；OnePlus 15、ROG Phone 9 Pro 等更高更新率的手機也適用\n"
          "• 螢幕：AOC 24G51F、Samsung Odyssey G5、Dell SE2426HS 等入門電競螢幕\n"
          "• 電視：LG C5（搭配電腦）、TCL QM8K；165Hz 的 LG G5、Samsung S95F 也適用\n"
          "• Apple 目前沒有 144Hz 以上的裝置")
menu = ('<div class="menu" style="left:82px;top:211px">' +
        "".join(f'<div class="{cls}">{t}</div>' for t, cls in menu_items) + "</div>" +
        f'<div class="tip" style="left:236px;top:330px">{tip144}</div>' + CURSOR.format(x=432, y=283))
pages["fps-menu"] = window('<div class="hint"></div>', overlay=menu)

jobs = SELBAR + f"""<div class="list" data-kind="job">
 <div class="job">{cb(False)}<div class="st" style="color:#34c759">✔</div><div class="main"><div class="name">旅行_台南.mov</div>
   <div class="sub">完成（48 秒）→ 旅行_台南_120fps.mov</div></div><span class="btn">在 Finder 中顯示</span><span class="x">✕</span></div>
 <div class="job">{cb(False, True)}<div class="st"><span class="spin"></span></div><div class="main"><div class="name">家人聚餐.mp4</div>
   <div class="bar"><i style="width:45%"></i></div><div class="sub">45%・剩餘約 12 秒　→ 120 FPS・精細・標準畫質</div>
   <div class="size">原檔 312 MB → 預估約 624 MB（120 FPS・標準畫質，實際可能小一些）</div></div></div>
 <div class="job">{cb(False, True)}<div class="st" style="color:#8e8e93">🕒</div><div class="main"><div class="name">夜市.mp4</div>
   <div class="sub">排隊中　→ 120 FPS・精細・標準畫質</div>
   <div class="size">原檔 120 MB → 預估約 240 MB（120 FPS・標準畫質，實際可能小一些）</div></div></div>
 <div class="job">{cb()}<div class="st" style="color:#8e8e93">📥</div><div class="main"><div class="name">生日派對.mov</div>
   <div class="sub">等待中（已勾選，按「開始轉檔」後開始）</div>
   <div class="size">原檔 96.4 MB → 預估約 193 MB（120 FPS・標準畫質，實際可能小一些）</div></div><span class="x">✕</span></div>
 <div class="job">{cb(False)}<div class="st" style="color:#8e8e93">⏭</div><div class="main"><div class="name">遊戲錄影_144fps.mov</div>
   <div class="sub">略過：這支影片已經是 144 FPS，不需要轉成 120 FPS。</div></div><span class="x">✕</span></div>
</div>"""
pages["converting"] = window(jobs, start="轉檔中…", running=True,
    note="轉檔中新加入的 1 支影片，會在這一輪結束後，勾選後再按一次「開始轉檔」才開始。")
adv_tip = ("存檔時用多少資料量記錄畫面（＝檔案大小）。高：檔案約為標準的 1.5 倍，細節最多。"
           "標準（預設）。省空間：約為標準的 0.6 倍，畫面可能比較糊。改了只影響之後加入的影片。")
pages["advanced"] = window('<div class="hint"></div>', advanced=True, outdir="~/Movies/120fps 影片",
    overlay=f'<div class="tip" style="left:300px;top:300px;width:300px">{adv_tip}</div>' + CURSOR.format(x=270, y=380))

# Concept figure: how frames are added (30 → 120)
FRAMES = """<!doctype html><html><head><meta charset="utf-8"><style>
body { margin:0; padding:26px 30px; background:#fff; font-family:'Noto Sans CJK TC','PingFang TC',sans-serif; color:#1d1d1f; width: 860px; }
h4 { margin: 0 0 8px; font-size: 15px; } .lane { display:flex; align-items:center; gap:6px; margin-bottom: 22px; }
.f { width: 44px; height: 32px; border-radius: 5px; display:flex; align-items:center; justify-content:center; font-size:11px; font-weight:700; }
.o { background:#1d4ed8; color:#fff; } .a { background:#bfdbfe; color:#1e3a8a; border: 1.5px dashed #3b82f6; }
.gap { width: 44px*3; } .legend { display:flex; gap:22px; font-size:13px; color:#444; align-items:center; }
.legend span.f { width: 22px; height: 16px; } .t { font-size: 12px; color:#666; margin-top: -14px; margin-bottom: 18px; }
.badge { float:right; background: rgba(255,149,0,.92); color:#fff; font-size:12px; font-weight:700; padding:3px 10px; border-radius:10px; }
</style></head><body>
<span class="badge">示意圖</span>
<h4>原本 30 FPS：每 1/30 秒一張</h4>
<div class="lane">{orig}</div>
<div class="t">時間 →　（從第 1 張到第 4 張 ＝ 0.1 秒）</div>
<h4>補幀後 120 FPS：每兩張原始畫面之間，由 Apple 的 AI 補出 3 張</h4>
<div class="lane">{boosted}</div>
<div class="legend"><span class="f o"></span>原始畫面（直接沿用）<span class="f a"></span>AI 補出的畫面（位置 0.25、0.5、0.75）</div>
</body></html>"""
orig = "".join(f'<div class="f o">{i+1}</div><div style="width:150px"></div>' if i < 3 else f'<div class="f o">{i+1}</div>' for i in range(4))
boosted = ""
for i in range(4):
    boosted += f'<div class="f o">{i+1}</div>'
    if i < 3:
        boosted += "".join(f'<div class="f a">+{j}</div>' for j in (1, 2, 3))
pages["frames-30-to-120"] = FRAMES.replace("{orig}", orig).replace("{boosted}", boosted)

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
        pg = await b.new_page(device_scale_factor=2, viewport={"width": 920, "height": 700})
        for name, html in pages.items():
            await pg.set_content(html)
            await pg.wait_for_timeout(150)
            await pg.locator("body").screenshot(path=str(OUT / f"{name}.png"))
            print("wrote", name)
        await b.close()

asyncio.run(main())
