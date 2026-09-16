#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 README 配图（docs/*.png）。

为什么用脚本而不是截图
----------------------
README 里的配图需要统一的背景、留白、字体和光影 —— 逐张手动截屏做不到，
而且截屏会把终端里的内容一起带进画面（旧版配图就有这个问题）。

这个脚本只替换「舞台」：App 图标是真实的（走 dockgroup 的图标提取），
拼贴图标走的是 `scripts/dockgroup.py` 里同一份 `make_mosaic()`，
面板几何取自 `scripts/launcher/main.swift` 的常量
（cell 86×100 / icon 58 / pad 16 / gap 7 / radius 25 / label 11pt）。

用法：
    /usr/bin/python3 tools/readme_assets.py

依赖：系统自带 `/usr/bin/python3`（含 Pillow）、SF Pro 字体（SFNS.ttf）。
注意：图上的文字一律用英文 —— SF Pro 没有中文字形，中文会渲染成方块。
"""
import sys
from math import ceil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import dockgroup as dg  # noqa: E402

DOCS = ROOT / "docs"
TMP = Path("/tmp/dockgroup-readme")
S = 2                      # 2× 渲染：GitHub 缩到 50% 显示时边缘依然锐利

# ── 配色 ──────────────────────────────────────────────────────────
BG_TOP, BG_BOT = (232, 237, 245), (203, 211, 226)
INK, INK_2, INK_3 = (26, 28, 34, 255), (99, 107, 122, 255), (140, 148, 163, 255)
PANEL_HUD = (56, 57, 60)
PANEL_MENU = (247, 248, 250)

FONT_PATH = "/System/Library/Fonts/SFNS.ttf"

# 真实面板几何（pt），对齐 scripts/launcher/main.swift
P_PAD, P_CW, P_CH, P_GAP, P_RADIUS, P_ICON, P_LABEL = 16, 86, 100, 7, 25, 58, 11
# 真实 Dock 几何（pt）
D_ICON, D_GAP, D_PADX, D_BAR_H, D_RADIUS = 58, 17, 20, 80, 22

# ── 真实 App（用系统自带 / 通用的，让陌生人也读得懂）──────────────
APP_PATHS = {
    "finder":     "/System/Library/CoreServices/Finder.app",
    "safari":     "/Applications/Safari.app",
    "chrome":     "/Applications/Google Chrome.app",
    "messages":   "/System/Applications/Messages.app",
    "mail":       "/System/Applications/Mail.app",
    "photos":     "/System/Applications/Photos.app",
    "music":      "/System/Applications/Music.app",
    "maps":       "/System/Applications/Maps.app",
    "settings":   "/System/Applications/System Settings.app",
    "notes":      "/System/Applications/Notes.app",
    "reminders":  "/System/Applications/Reminders.app",
    "calendar":   "/System/Applications/Calendar.app",
    "calculator": "/System/Applications/Calculator.app",
}

# 演示用分组：4 个通用 App，正好填满 2×2
GROUP = ["calendar", "notes", "reminders", "calculator"]
GROUP_NAMES = ["Calendar", "Notes", "Reminders", "Calculator"]

STYLES = [
    ("graphite",    "dark graphite · the default"),
    ("glass-dark",  "deepest black glass"),
    ("dock",        "matches the Dock bar"),
    ("dock-deep",   "one step darker"),
    ("frost-light", "translucent light"),
    ("frost-blue",  "cool blue tint"),
    ("paper",       "near-white, cleanest"),
]

_ICONS = {}
_TILE_EPOCH = 0.0


# ── 基础绘制工具 ──────────────────────────────────────────────────
def q(v):
    """pt → 像素。"""
    return int(round(v * S))


def font(px, weight=400):
    f = ImageFont.truetype(FONT_PATH, px)
    try:
        f.set_variation_by_axes([100, min(96, max(17, px)), 400, weight])
    except Exception:
        pass
    return f


def vgrad(w, h, top, bottom):
    """竖直渐变。逐行算完一次性 putdata —— PIL 放大 2px 源会得到假渐变。"""
    span = max(h - 1, 1)
    ramp = [tuple(int(top[i] + (bottom[i] - top[i]) * y / span) for i in range(3)) + (255,)
            for y in range(h)]
    row = Image.new("RGBA", (1, h))
    row.putdata(ramp)
    return row.resize((w, h), Image.NEAREST)


def rmask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1),
                                        radius=radius, fill=255)
    return m


def blob(canvas, cx, cy, r, color, alpha):
    """背景柔光斑：让毛玻璃有东西可采样，画面也不至于死平。"""
    m = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(m).ellipse((cx - r, cy - r, cx + r, cy + r), fill=int(255 * alpha))
    m = m.filter(ImageFilter.GaussianBlur(r * 0.45))
    canvas.paste(Image.new("RGBA", canvas.size, tuple(color) + (255,)), (0, 0), m)


def background(w, h):
    """所有配图共用的舞台：浅色渐变 + 三团很淡的柔光。"""
    bg = vgrad(w, h, BG_TOP, BG_BOT)
    blob(bg, int(w * 0.14), int(h * 0.06), int(h * 0.58), (152, 186, 234), 0.32)
    blob(bg, int(w * 0.90), int(h * 0.96), int(h * 0.62), (234, 198, 170), 0.22)
    blob(bg, int(w * 0.58), int(h * 0.38), int(h * 0.44), (255, 255, 255), 0.28)
    return bg


def drop_shadow(canvas, box, radius, blur, dy, alpha, color=(22, 26, 38)):
    m = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (box[0], box[1] + dy, box[2], box[3] + dy), radius=radius, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * alpha))
    canvas.paste(Image.new("RGBA", canvas.size, color + (255,)), (0, 0), m)


def frost(canvas, box, radius, tint, alpha, blur=14, inner_light=None):
    """毛玻璃：采样背后内容 → 模糊 → 叠色 → 圆角裁切。

    真的算出 `behindWindow` 做不到，但「采样背景再叠色」比「直接填一个死色」
    真实得多：边角会自然带出背景的明暗。**必须画在最终画布上**，
    不能先在别处画好再贴过来 —— 那样会留下一块矩形接缝。
    """
    x0, y0, x1, y1 = [int(round(v)) for v in box]
    region = canvas.crop((x0, y0, x1, y1)).filter(ImageFilter.GaussianBlur(blur))
    mixed = Image.blend(region.convert("RGB"), Image.new("RGB", region.size, tint), alpha)
    canvas.paste(mixed.convert("RGBA"), (x0, y0), rmask(region.size, radius))
    if inner_light:
        ImageDraw.Draw(canvas).rounded_rectangle(
            box, radius=radius, outline=tuple(inner_light[:3]) + (inner_light[3],),
            width=max(1, q(0.75)))


def paste_icon(canvas, im, pos, shadow=None):
    if shadow:
        dv, blur, alpha = shadow
        m = Image.new("L", canvas.size, 0)
        m.paste(im.split()[3], (pos[0], pos[1] + dv))
        m = m.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * alpha))
        canvas.paste(Image.new("RGBA", canvas.size, (18, 22, 32, 255)), (0, 0), m)
    canvas.alpha_composite(im, pos)


def app_icon(key, px, shadow=None):
    src = _ICONS[key]
    return Image.open(src).convert("RGBA").resize((px, px), Image.LANCZOS)


def tile_icon(style, keys, px):
    out = TMP / "tiles" / f"{style}-{'-'.join(keys)}.png"
    if not out.exists() or out.stat().st_mtime < _TILE_EPOCH:
        dg.make_mosaic([_ICONS[k] for k in keys], out, size=1024, style=style)
    return Image.open(out).convert("RGBA").resize((px, px), Image.LANCZOS)


def fit(d, s, f, width):
    """超宽就截断加省略号（和面板里 .byTruncatingTail 一个意思）。"""
    if d.textlength(s, font=f) <= width:
        return s
    while s and d.textlength(s + "…", font=f) > width:
        s = s[:-1]
    return s + "…"


def save(img, name):
    DOCS.mkdir(parents=True, exist_ok=True)
    out = DOCS / name
    img.convert("RGB").save(out, "PNG", optimize=True)
    print(f"  {out.relative_to(ROOT)}  {img.width}×{img.height}  "
          f"{out.stat().st_size / 1024:.0f} KB")


# ── Dock 栏 ──────────────────────────────────────────────────────
def dock_strip(canvas, y_top, items, tile_pos, tile_style, tile_keys,
               highlight=False):
    """画一条 Dock 栏。items = [("app", key) | ("tile", None)]。
    返回 (bar_box, tile_center_x, bar_width)。"""
    n = len(items)
    iw, gp, pax, bh = q(D_ICON), q(D_GAP), q(D_PADX), q(D_BAR_H)
    bw = pax * 2 + n * iw + (n - 1) * gp
    x0 = canvas.width // 2 - bw // 2
    box = (x0, y_top, x0 + bw, y_top + bh)

    drop_shadow(canvas, box, q(D_RADIUS), q(9), q(5), 0.18)
    frost(canvas, box, q(D_RADIUS), (255, 255, 255), 0.50, blur=q(10),
          inner_light=(255, 255, 255, 150))

    iy = y_top + (bh - iw) // 2
    tile_cx = None
    for i, (kind, key) in enumerate(items):
        ix = x0 + pax + i * (iw + gp)
        if kind == "app":
            paste_icon(canvas, app_icon(key, iw), (ix, iy))
        else:
            if highlight:
                ImageDraw.Draw(canvas).rounded_rectangle(
                    (ix - q(5), iy - q(5), ix + iw + q(5), iy + iw + q(5)),
                    radius=q(15), outline=(255, 255, 255, 215), width=q(1.6))
            paste_icon(canvas, tile_icon(tile_style, tile_keys, iw), (ix, iy))
            tile_cx = ix + iw // 2
    return box, tile_cx, bw


# ── 弹出面板（直接画在最终画布上）─────────────────────────────────
def panel_box(keys, cols, cx, top_y):
    rows, c = ceil(len(keys) / cols), min(len(keys), cols)
    pw = c * q(P_CW) + (c - 1) * q(P_GAP) + 2 * q(P_PAD)
    ph = rows * q(P_CH) + (rows - 1) * q(P_GAP) + 2 * q(P_PAD)
    return (cx - pw // 2, top_y, cx + pw // 2, top_y + ph)


def draw_panel(canvas, keys, names, top_y, material="hud", cols=4, hover=None,
               cx=None):
    """按 main.swift 的几何在画布上画一个面板，返回面板 box。"""
    cx = canvas.width // 2 if cx is None else cx
    box = panel_box(keys, cols, cx, top_y)
    pw, ph = box[2] - box[0], box[3] - box[1]
    pad, gap = q(P_PAD), q(P_GAP)

    drop_shadow(canvas, box, q(P_RADIUS), q(11), q(4), 0.26)
    dark = material in ("hud", "toolTip")
    frost(canvas, box, q(P_RADIUS), PANEL_HUD if dark else PANEL_MENU,
          0.90 if dark else 0.86, blur=q(12),
          inner_light=(255, 255, 255, 40) if dark else (255, 255, 255, 220))

    d = ImageDraw.Draw(canvas)
    ic, n = q(P_ICON), len(keys)
    for i, key in enumerate(keys):
        r, col = divmod(i, cols)
        in_row = min(cols, n - r * cols)
        row_w = in_row * q(P_CW) + (in_row - 1) * gap
        row_x = box[0] + pad + (pw - 2 * pad - row_w) // 2
        cell_x = row_x + col * (q(P_CW) + gap)
        cell_y = box[1] + pad + r * (q(P_CH) + gap)
        if hover == i:
            d.rounded_rectangle((cell_x + q(3), cell_y + q(4),
                                 cell_x + q(P_CW) - q(3), cell_y + q(P_CH) - q(4)),
                                radius=q(15), fill=(255, 255, 255, 38))
        paste_icon(canvas, app_icon(key, ic), (cell_x + (q(P_CW) - ic) // 2,
                                               cell_y + q(12)),
                   shadow=(q(1.5), q(4), 0.30))
        lf = font(q(P_LABEL), weight=500 if hover == i else 400)
        tone = (255, 255, 255, int(255 * (0.98 if hover == i else 0.78))) if dark \
            else (0, 0, 0, int(255 * (0.92 if hover == i else 0.70)))
        d.text((cell_x + q(P_CW) // 2, cell_y + q(79)),
               fit(d, names[i], lf, q(P_CW) - q(10)), font=lf, fill=tone, anchor="ma")
    return box


# ── 配图 ─────────────────────────────────────────────────────────
def fig_hero():
    """首图：Dock 里一个 tile + 点开后原位弹出的分组面板。"""
    W, H = q(840), q(344)
    img = background(W, H)

    items = [("app", "finder"), ("app", "safari"), ("app", "chrome"),
             ("tile", None), ("app", "messages"), ("app", "mail"),
             ("app", "photos"), ("app", "music")]
    bar_y = H - q(28) - q(D_BAR_H)
    box, tile_cx, _ = dock_strip(img, bar_y, items, 3, "graphite", GROUP,
                                 highlight=True)
    draw_panel(img, GROUP, GROUP_NAMES, box[1] - q(16) - q(132),
               material="hud", cx=tile_cx)
    save(img, "hero.png")


def fig_dock_tile():
    """「在 Dock 里长什么样」：实尺 Dock 条 + 拼贴是怎么来的。"""
    W, H = q(840), q(486)
    img = background(W, H)
    d = ImageDraw.Draw(img)
    cap, note = font(q(11)), font(q(12), weight=600)

    items = [("app", "finder"), ("app", "safari"), ("app", "chrome"),
             ("app", "messages"), ("tile", None), ("app", "mail"),
             ("app", "photos"), ("app", "maps"), ("app", "music"),
             ("app", "settings")]
    box, _, _ = dock_strip(img, q(32), items, 4, "graphite", GROUP, highlight=True)
    d.text((box[0], box[3] + q(12)), "system Dock · real scale", font=cap, fill=INK_3)

    d.text((W // 2, q(168)), "the tile is a 2×2 collage of the real app icons",
           font=note, fill=INK_2, anchor="mm")

    top, big, src, gap = q(196), q(232), q(72), q(18)
    sw = len(GROUP) * src + (len(GROUP) - 1) * gap
    total = sw + q(64) + big
    sx = (W - total) // 2
    for i, k in enumerate(GROUP):
        paste_icon(img, app_icon(k, src), (sx + i * (src + gap), top + (big - src) // 2),
                   shadow=(q(3), q(6), 0.18))

    ax = sx + sw + q(12)
    cy = top + big // 2
    d.line([(ax, cy - q(11)), (ax + q(30), cy), (ax + q(30), cy), (ax, cy + q(11))],
           fill=INK_3, width=q(2.5), joint="curve")
    paste_icon(img, tile_icon("graphite", GROUP, big), (ax + q(48), top),
               shadow=(q(4), q(10), 0.20))

    d.text((sx + sw // 2, top + big + q(14)), "4 apps in one folder", font=cap,
           fill=INK_3, anchor="ma")
    d.text((ax + q(48) + big // 2, top + big + q(14)), "one Dock tile  ·  shown 4×",
           font=cap, fill=INK_3, anchor="ma")
    save(img, "dock-tile.png")


def fig_icon_styles():
    """7 种拼贴图标风格 + 真实 Dock 尺寸下的样子。"""
    W, H = q(840), q(586)
    img = background(W, H)
    d = ImageDraw.Draw(img)

    d.text((q(30), q(22)), "Icon styles", font=font(q(18), weight=700), fill=INK)
    d.text((q(30), q(50)), "built from the app icons inside the folder · switch with  dg style",
           font=font(q(11)), fill=INK_2)

    cw, ch, gap = q(192), q(148), q(12)
    x0, y0 = (W - (4 * cw + 3 * gap)) // 2, q(84)
    for i, (name, note) in enumerate(STYLES):
        r, c = divmod(i, 4)
        bx, by = x0 + c * (cw + gap), y0 + r * (ch + gap)
        d.rounded_rectangle((bx, by, bx + cw, by + ch), radius=q(12),
                            fill=(255, 255, 255, 130), outline=(255, 255, 255, 180),
                            width=q(1))
        paste_icon(img, tile_icon(name, GROUP, q(78)),
                   (bx + (cw - q(78)) // 2, by + q(14)), shadow=(q(2), q(7), 0.24))
        d.text((bx + cw // 2, by + q(104)), name, font=font(q(12), weight=600),
               fill=INK, anchor="ma")
        d.text((bx + cw // 2, by + q(124)), note, font=font(q(9.5)), fill=INK_3,
               anchor="ma")

    fy = q(444)
    d.text((W // 2, fy - q(16)), "all seven, at real Dock size (58 px)",
           font=font(q(11), weight=600), fill=INK_2, anchor="mm")
    px, gp = q(D_ICON), q(16)
    row_w = 7 * px + 6 * gp
    bar_y = q(456)
    bar = ((W - row_w) // 2 - q(24), bar_y,
           (W + row_w) // 2 + q(24), bar_y + q(D_BAR_H))
    drop_shadow(img, bar, q(D_RADIUS), q(9), q(5), 0.20)
    frost(img, bar, q(D_RADIUS), (255, 255, 255), 0.60, blur=q(10),
          inner_light=(255, 255, 255, 150))
    for i, (name, _) in enumerate(STYLES):
        ix = (W - row_w) // 2 + i * (px + gp)
        paste_icon(img, tile_icon(name, GROUP, px),
                   (ix, bar_y + (q(D_BAR_H) - px) // 2))
        d.text((ix + px // 2, bar_y + q(D_BAR_H) + q(10)), name, font=font(q(9)),
               fill=INK_3, anchor="ma")
    save(img, "icon-styles.png")


def fig_panel_materials():
    """面板材质：hud（默认深色）vs menu（浅色）。"""
    W, H = q(840), q(236)
    img = background(W, H)
    d = ImageDraw.Draw(img)

    for i, (mat, title, note) in enumerate([
            ("hud", "hud · default", "dark glass — white app icons stay readable"),
            ("menu", "menu", "light glass — closest to the Dock bar")]):
        cx = q(213) if i == 0 else q(627)
        x = cx - q(197)
        d.text((x, q(24)), title, font=font(q(13), weight=600), fill=INK)
        d.text((x, q(44)), note, font=font(q(10)), fill=INK_2)
        draw_panel(img, GROUP, GROUP_NAMES, q(70), material=mat, cx=cx)
    save(img, "panel-materials.png")


def fig_panel_grid():
    """多行排列：4 列排满自动换行，最后一行独立居中。"""
    W, H = q(840), q(330)
    img = background(W, H)
    d = ImageDraw.Draw(img)

    seven = ["calendar", "notes", "reminders", "calculator", "mail", "maps", "photos"]
    names = ["Calendar", "Notes", "Reminders", "Calculator", "Mail", "Maps", "Photos"]
    d.text((W // 2, q(30)), "4 per row · extra icons wrap · each row centres itself",
           font=font(q(12), weight=600), fill=INK_2, anchor="mm")
    draw_panel(img, seven, names, q(62), material="hud", cols=4)
    save(img, "panel-grid.png")


def fig_panel_radius():
    """圆角效果属于实现细节，图放在 references/ 里由 pitfalls.md 引用，不进 README。"""
    return


def main():
    global _ICONS, _TILE_EPOCH
    TMP.mkdir(parents=True, exist_ok=True)
    print("取 App 图标…")
    found = dg.app_icons([Path(p) for p in APP_PATHS.values()])
    _ICONS = {k: found.get(Path(p)) for k, p in APP_PATHS.items()}
    missing = [k for k, v in _ICONS.items() if not v]
    if missing:
        raise SystemExit(f"这些 App 的图标没取到：{missing}")
    _TILE_EPOCH = Path(dg.__file__).stat().st_mtime

    print("画图…")
    fig_hero()
    fig_dock_tile()
    fig_icon_styles()
    fig_panel_materials()
    fig_panel_grid()


if __name__ == "__main__":
    main()
