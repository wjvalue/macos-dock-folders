#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dockgroup — 把 macOS Dock 里的一组 App 折叠成一个 iPhone 风格的图标。

背景
----
macOS 原生不支持「把一个 Dock 图标拖到另一个上合并成文件夹」（那是 iOS 的交互）。
Dock 只支持把「文件夹」放进去，而且**文件夹的点击弹出网格只在分隔线右侧有效** ——
放进左侧 App 区后点击只会打开 Finder 窗口。所以本工具有两条路：

  placement="right"  文件夹 Stack（directory-tile）
                     原生网格弹窗，但只能待在分隔线右侧
  placement="left"   启动器 App（file-tile）
                     编译一个极小 App 固定在左侧 App 区，点击在自己图标正上方
                     弹出图标网格。位置随意，点击行为完全自己控制（默认）

两种模式共用的部分：
  1. 生成 <组名> 文件夹，里面放指向各个 App 的**真 Finder 别名**（无小箭头角标）
  2. 读取每个 App 的原始图标，实时合成一张 2×2 拼贴图标
  3. 把结果以正确的 tile 结构写入 Dock

**分组文件夹是唯一事实来源**：往 ~/Dock Groups/<组名>/ 里加/删 App，
启动器运行时现读该文件夹；只需跑 rebuild 刷新拼贴图标。

依赖：系统自带 /usr/bin/python3（含 PIL）+ osascript；
      左侧模式额外需要 swiftc（随 Xcode Command Line Tools 提供）。
      跑 `doctor` 可以体检。

用法
----
    doctor                体检：检查依赖是否齐全
    init [--force]        扫描当前 Dock，生成 starter groups.json
    new 组名 "App" ...     新建分组（App 名支持模糊匹配）
    preview [组名...]     预览拼贴图标，不改动 Dock
    apply   [组名...]     生成并写入 Dock（不填 = 全部启用中的分组）
                          --keep-originals 保留左侧原图标，不自动摘除
    rebuild [--quiet]     按文件夹现状刷新别名与图标，并重启 Dock
    list                  查看配置与 Dock 当前状态
    open    组名          在 Finder 里打开分组文件夹（往里面拖 App）
    test    组名          手动启动一次启动器，验证点击展开效果
    logs    组名          查看该分组的运行日志（面板几何 + 点击事件轨迹）
    logs    组名          查看该分组的运行日志（面板几何 + 点击事件轨迹）
    remove  组名...       从 Dock 移除（保留文件夹）
    clean   组名...       从 Dock 移除并删除文件夹
    watch-install         安装自动监听（文件夹一变就自动刷新图标）
    watch-uninstall       卸载自动监听
    restore [备份]        从最近一次备份恢复 Dock

环境变量
--------
    DOCKGROUP_HOME        落盘目录，默认 ~/Dock Groups
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

__version__ = "1.0.0"

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    sys.exit("需要 Pillow：请用 /usr/bin/python3 运行本脚本（系统自带 PIL）")

HOME = Path.home()
SCRIPT_DIR = Path(__file__).resolve().parent
BASE = Path(os.environ.get("DOCKGROUP_HOME") or (HOME / "Dock Groups")).expanduser()
CACHE = BASE / ".cache"              # 图标缓存
BACKUP = BASE / ".backup"            # Dock 备份
APPS = BASE / ".apps"                # 生成的启动器 App（左侧 App 区用）
CONFIG_PATH = BASE / "groups.json"
DOCK_DOMAIN = "com.apple.dock"
AGENT_LABEL = "local.dockgroup.watch"
AGENT_PLIST = HOME / "Library/LaunchAgents" / f"{AGENT_LABEL}.plist"
BUNDLE_PREFIX = "local.dockgroup.app"

# iOS 主屏文件夹的几何比例（相对文件夹边长）
ICON_INSET = 0.075      # 画布四周留白，对齐普通 App 图标 86.5% 的内容占比
BG_RADIUS = 0.235       # 文件夹底圆角

# 拼贴图标风格预设
#   bg  : 底板渐变 (顶, 底)，None = 无底板
#   hair: 内圈高光描边（玻璃质感的关键）
#   edge: 外圈描边 (颜色, 边距系数)
#   cell: 单个 App 图标占文件夹边长的比例
#   pad/gap: 网格内边距 / 格子间距（占文件夹边长比例）
#   shadow: 是否加投影（让图标从 Dock 上"浮"起来）
STYLES = {
    # 与 Dock 栏同调的浅灰（默认）。白底 App 图标在这个灰度上能显出形状
    "dock": dict(
        bg=((238, 239, 243, 252), (212, 214, 222, 253)),
        hair=(255, 255, 255, 195), edge=((132, 135, 148, 125), 0.0025),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=True),
    # 比 dock 再深一档，白图标对比更强
    "dock-deep": dict(
        bg=((226, 228, 234, 252), (188, 191, 203, 253)),
        hair=(255, 255, 255, 205), edge=((110, 114, 129, 142), 0.0025),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=True),
    "paper": dict(
        bg=((255, 255, 255, 253), (238, 239, 244, 253)),
        hair=(255, 255, 255, 225), edge=((146, 149, 160, 135), 0.0022),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=True),
    "frost-light": dict(
        bg=((248, 249, 252, 248), (196, 201, 213, 251)),
        hair=(255, 255, 255, 205), edge=((112, 116, 132, 115), 0.0025),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=True),
    "frost-blue": dict(
        bg=((224, 235, 251, 249), (154, 182, 222, 251)),
        hair=(255, 255, 255, 210), edge=((74, 108, 158, 120), 0.0025),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=True),
    "glass-dark": dict(
        bg=((90, 91, 101, 249), (28, 29, 35, 252)),
        hair=(255, 255, 255, 125), edge=((0, 0, 0, 145), 0.0025),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=False),
    "graphite": dict(
        bg=((124, 126, 136, 250), (68, 70, 80, 252)),
        hair=(255, 255, 255, 155), edge=((0, 0, 0, 155), 0.0025),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=False),
}
DEFAULT_STYLE = "dock"

# 预览图字体（macOS 26 已移除 PingFang.ttc）
FONT_CANDIDATES = [
    ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2),   # W6
    ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),   # W3
    ("/System/Library/Fonts/STHeiti Medium.ttc", 1),
    ("/System/Library/Fonts/PingFang.ttc", 0),
    ("/System/Library/Fonts/Helvetica.ttc", 0),
]

ICON_ENTRY = "Icon" + "\r"   # 文件夹自定义图标的载体文件

# 缓存里 App 图标的边长上限。图标格子最大约 540px（单 App 分组时），512 足够；
# 而 AppKit 产出的原图是 1297 KB 的 1024px，缩小后每次解码快约 4 倍。
ICON_SRC_PX = 512


# ─────────────────────────────────────────────────────────── 基础工具

def sh(cmd, check=False):
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def uid() -> str:
    return subprocess.run(["id", "-u"], capture_output=True, text=True).stdout.strip()


# Finder 自动化被 TCC 拦截（-10004），所以全部走 Foundation，不碰 Finder。
JXA = {
    # 取 App 图标：能正确处理 Assets.car，比翻 Contents/Resources/*.icns 可靠
    "grab": """
ObjC.import('AppKit');
function run(argv) {
  const icon = $.NSWorkspace.sharedWorkspace.iconForFile(argv[0]);
  icon.size = $.NSMakeSize(1024, 1024);
  const rep = $.NSBitmapImageRep.imageRepWithData(icon.TIFFRepresentation);
  const png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
  png.writeToFileAtomically($(argv[1]), true);
}
""",
    # 批量取图标（argv 为 src1, out1, src2, out2, ...）。
    # 每起一个 osascript 做 AppKit 图标渲染约 400ms，逐 App 起进程是最大的性能坑。
    "grab_many": """
ObjC.import('AppKit');
function run(argv) {
  const done = [];
  for (let i = 0; i + 1 < argv.length; i += 2) {
    const icon = $.NSWorkspace.sharedWorkspace.iconForFile(argv[i]);
    icon.size = $.NSMakeSize(1024, 1024);
    const rep = $.NSBitmapImageRep.imageRepWithData(icon.TIFFRepresentation);
    const png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
    done.push(png && png.writeToFileAtomically($(argv[i + 1]), true) ? 'ok' : 'fail');
  }
  return done.join(String.fromCharCode(10));
}
""",
    # 建真 Finder 别名（NSURLBookmarkCreationSuitableForBookmarkFile = 1<<10）
    "mkalias": """
ObjC.import('Foundation');
function run(argv) {
  const dir = argv[0] + '/';
  const made = [];
  for (let i = 1; i < argv.length; i++) {
    const src = argv[i];
    let base = src.replace(/\\/$/, '').split('/').pop();
    if (base.endsWith('.app')) base = base.slice(0, -4);
    const dst = dir + base;
    if ($.NSFileManager.defaultManager.fileExistsAtPath(dst)) { made.push(base); continue; }
    const su = $.NSURL.fileURLWithPath(src);
    const data = su.bookmarkDataWithOptionsIncludingResourceValuesForKeysRelativeToURLError(1024, $(), $(), $());
    if (!data) continue;
    const du = $.NSURL.fileURLWithPath(dst);
    if ($.NSURL.writeBookmarkDataToURLOptionsError(data, du, 0, $())) made.push(base);
  }
  return made.join(String.fromCharCode(10));
}
""",
    # 批量解析别名 → 真实路径（非别名原样返回）
    "rdalias": """
ObjC.import('Foundation');
function run(argv) {
  const out = [];
  for (let i = 0; i < argv.length; i++) {
    const u = $.NSURL.fileURLWithPath(argv[i]);
    const r = $.NSURL.URLByResolvingAliasFileAtURLOptionsError(u, 256, $());
    out.push(r ? ObjC.unwrap(r.path) : '');
  }
  return out.join(String.fromCharCode(10));
}
""",
    # 设置文件夹自定义图标：走 AppKit 官方 API，系统自己做 icns/资源分支处理
    "seticon": """
ObjC.import('AppKit');
function run(argv) {
  const img = $.NSImage.alloc.initWithContentsOfFile(argv[1]);
  if (!img) return 'no-image';
  if ($.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, argv[0], 0)) return 'ok';
  return 'fail';
}
""",
    # 生成 Dock tile 里的 book 字段（magic 与 Dock 自己写的一致）
    "bookmark": """
ObjC.import('Foundation');
function run(argv) {
  const u = $.NSURL.fileURLWithPath(argv[0]);
  const d = u.bookmarkDataWithOptionsIncludingResourceValuesForKeysRelativeToURLError(0, $(), $(), $());
  if (!d) return 'FAIL';
  return ObjC.unwrap(d.base64EncodedStringWithOptions(0));
}
""",
    # 按名字找 App（能覆盖 Safari 这类不在 /Applications 里的系统 App）
    "findapp": """
ObjC.import('AppKit');
function run(argv) {
  const p = $.NSWorkspace.sharedWorkspace.fullPathForApplication(argv[0]);
  return p ? ObjC.unwrap(p) : '';
}
""",
}


def jxa_path(key: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    p = CACHE / f"{key}.jxa"
    if not p.exists() or p.read_text() != JXA[key]:
        p.write_text(JXA[key])
    return p


def jxa(key: str, *args):
    """跑一段 JXA。返回值按行切分 —— 各脚本统一用 \\n 作分隔符，
    这样路径里出现 ", " 也不会把结果切错；空行保留，维持「位置 ↔ 条目」的对应关系。"""
    r = sh(["osascript", "-l", "JavaScript", str(jxa_path(key))] + [str(a) for a in args])
    if r.returncode != 0:
        return None
    out = r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout
    return out.split("\n") if out else []


# ─────────────────────────────────────────────────────────── 配置

def load_config() -> dict:
    for p in (CONFIG_PATH, SCRIPT_DIR / "groups.json"):
        if p.exists():
            with p.open(encoding="utf-8") as f:
                return json.load(f)
    return {"groups": []}


def save_config(cfg: dict):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CONFIG_PATH.open("w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")


def find_group(cfg, name):
    return next((g for g in cfg["groups"] if g["name"] == name), None)


# ─────────────────────────────────────────────────────────── 图标提取与合成

def _icon_cache(app: Path):
    """图标缓存路径（按 路径 + mtime 作 key），App 不存在返回 None。"""
    if not app.exists():
        return None
    try:
        key = f"{app.stem}-{int(app.stat().st_mtime)}"
    except OSError:
        key = app.stem
    return CACHE / "app-icons" / f"{key}.png"


def _shrink_cache(png: Path):
    """把缓存里的原图缩到 ICON_SRC_PX。写临时文件再替换，避免写坏缓存。"""
    try:
        im = Image.open(png)
        if max(im.size) <= ICON_SRC_PX:
            return
        small = im.convert("RGBA").resize((ICON_SRC_PX, ICON_SRC_PX), Image.LANCZOS)
        tmp = png.with_suffix(".tmp.png")
        small.save(tmp, "PNG")
        tmp.replace(png)
    except Exception:
        pass


def app_icons(apps):
    """批量取图标 → {Path: Path}。只起一个 osascript，缺哪个补哪个。"""
    jobs, pending = {}, []
    for a in apps:
        out = _icon_cache(a)
        if out is None:
            continue
        jobs[a] = out
        if not (out.exists() and out.stat().st_size > 0):
            pending += [str(a), str(out)]

    if pending:
        for p in jobs.values():
            p.parent.mkdir(parents=True, exist_ok=True)
        r = sh(["osascript", "-l", "JavaScript", str(jxa_path("grab_many"))] + pending)
        if r.returncode != 0:   # 批量失败就逐个兜底，保证不会整组空图标
            for i in range(0, len(pending), 2):
                jxa("grab", pending[i], pending[i + 1])
        for out in set(jobs.values()):
            _shrink_cache(out)

    return {a: p for a, p in jobs.items() if p.exists() and p.stat().st_size > 0}


def app_icon(app: Path):
    """单个 App 的图标路径（外部脚本/测试用的便捷包装）。"""
    return app_icons([app]).get(app)


def _vertical_gradient(size, top, bottom):
    """竖直渐变。逐行算好后一次性 putdata，避免 size 次 putpixel 调用。

    注意别图省事改成「建 1x2 再 resize」：PIL 放大时按半像素对齐，
    2 像素源会变成上下各约 1/4 是平的、只有中间是渐变。"""
    span = max(size - 1, 1)
    ramp = [tuple(int(top[i] + (bottom[i] - top[i]) * y / span) for i in range(4))
            for y in range(size)]
    row = Image.new("RGBA", (1, size))
    row.putdata(ramp)
    return row.resize((size, size), Image.NEAREST)


def _drop_shadow(canvas, icon, pos, blur=0.011, offset=0.007, strength=0.34):
    """在 canvas 上、icon 位置的下方画一层柔和投影。

    为什么需要：白底的 App 图标（Hermes / WorkBuddy 这类白圆角方块）
    放在浅色底板上会和背景糊成一片，只剩中间的黑 logo 能看见，形状丢了。
    加一层投影，图标的轮廓就立起来了。
    """
    S = canvas.width
    mask = Image.new("L", canvas.size, 0)
    mask.paste(icon.split()[3], (pos[0], pos[1] + max(1, int(S * offset))))
    mask = mask.filter(ImageFilter.GaussianBlur(max(2, int(S * blur))))
    mask = mask.point(lambda v: int(v * strength))
    canvas.paste(Image.new("RGBA", canvas.size, (30, 32, 42, 255)), (0, 0), mask)


def make_mosaic(icon_paths, out, size: int = 1024,
                style: str = DEFAULT_STYLE) -> Path:
    """把若干 App 图标合成一张 iOS 风格的文件夹图标。"""
    out = Path(out)
    S = size
    st = STYLES.get(style, STYLES[DEFAULT_STYLE])
    inset = int(S * ICON_INSET)
    box = (inset, inset, S - inset, S - inset)
    side = box[2] - box[0]
    radius = int(side * BG_RADIUS)

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 投影：让图标从 Dock 上浮起来
    if st["shadow"]:
        pad_sh = int(S * 0.030)
        sh_mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(sh_mask).rounded_rectangle(
            (box[0] + pad_sh, box[1] + pad_sh + int(S * 0.012),
             box[2] - pad_sh, box[3] - pad_sh + int(S * 0.012)),
            radius=radius, fill=150)
        sh_mask = sh_mask.filter(ImageFilter.GaussianBlur(int(S * 0.022)))
        canvas.paste(Image.new("RGBA", (S, S), (24, 26, 34, 255)), (0, 0), sh_mask)

    # 底板
    if st["bg"]:
        grad = _vertical_gradient(S, st["bg"][0], st["bg"][1])
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
        canvas.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(canvas)
    if st["hair"]:
        # 内圈高光：玻璃质感来源
        d.rounded_rectangle(box, radius=radius, outline=st["hair"],
                            width=max(2, int(S * 0.0045)))
    if st["edge"]:
        col, o = st["edge"]
        off = max(1, int(S * o))
        d.rounded_rectangle((box[0] - off, box[1] - off, box[2] + off, box[3] + off),
                            radius=radius + off, outline=col, width=off)

    n = len(icon_paths)
    pad, gap = int(side * st["pad"]), int(side * st["gap"])
    cell = (side - 2 * pad - gap) // 2
    if n == 1:
        cell = int(side * 0.62)
        slots = [((side - cell) // 2, (side - cell) // 2)]
    elif n == 2:
        cell = int(side * 0.55)
        gap = int(side * 0.08)
        x0 = (side - 2 * cell - gap) // 2
        y0 = (side - cell) // 2
        slots = [(x0, y0), (x0 + cell + gap, y0)]
    else:
        slots = [(pad, pad), (pad + cell + gap, pad),
                 (pad, pad + cell + gap), (pad + cell + gap, pad + cell + gap)]

    with_icon_shadow = st.get("icon_shadow", False)
    for i, ip in enumerate(icon_paths[:4]):
        try:
            ic = Image.open(ip).convert("RGBA").resize((cell, cell), Image.LANCZOS)
        except Exception:
            continue
        pos = (inset + slots[i][0], inset + slots[i][1])
        if with_icon_shadow:
            _drop_shadow(canvas, ic, pos)
        canvas.alpha_composite(ic, pos)

    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out, "PNG")
    return out


def make_contact_sheet(items, out, bg=(255, 255, 255, 255)) -> Path:
    out = Path(out)
    big, small, pad = 176, 64, 34
    w = max(560, pad + len(items) * (big + pad))
    h = pad + big + 46 + small + pad
    sheet = Image.new("RGBA", (w, h), bg)
    d = ImageDraw.Draw(sheet)

    font = None
    for cand, idx in FONT_CANDIDATES:
        if not Path(cand).exists():
            continue
        try:
            font = ImageFont.truetype(cand, 26, index=idx)
            break
        except Exception:
            continue
    if font is None:
        font = ImageFont.load_default()

    x = pad
    for label, png in items:
        im = Image.open(png).convert("RGBA")
        sheet.alpha_composite(im.resize((big, big), Image.LANCZOS), (x, pad))
        sheet.alpha_composite(im.resize((small, small), Image.LANCZOS),
                              (x + (big - small) // 2, pad + big + 34))
        tw = d.textlength(label, font=font)
        d.text((x + (big - tw) / 2, pad + big + 8), label, fill=(40, 40, 45, 255), font=font)
        x += big + pad

    sheet.convert("RGB").save(out, "PNG")
    return out


def set_folder_icon(folder, png) -> bool:
    folder = Path(folder)
    """用 AppKit 官方 setIcon:forFile:options: 设置文件夹自定义图标。

    不要手写 Icon\\r + SetFile -a C：那样 Finder 认，但 IconServices 渲染不出，
    Dock 上仍显示蓝色文件夹。官方 API 会正确处理 icns 与资源分支。
    """
    return (jxa("seticon", folder, png) or [])[:1] == ["ok"]


# ─────────────────────────────────────────────────────────── 启动器 App

LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")


def png_to_icns(png, icns) -> Path:
    png, icns = Path(png), Path(icns)
    with tempfile.TemporaryDirectory() as td:
        iconset = Path(td) / "icon.iconset"
        iconset.mkdir()
        for fname, px in [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
                          ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                          ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                          ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                          ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)]:
            sh(["sips", "-z", str(px), str(px), str(png), "--out", str(iconset / fname)])
        icns.parent.mkdir(parents=True, exist_ok=True)
        sh(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    return icns


def bundle_id(app: Path):
    try:
        with (app / "Contents/Info.plist").open("rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except Exception:
        return None


def bookmark_bytes(app: Path):
    out = jxa("bookmark", app)
    if not out or out[0] == "FAIL":
        return None
    try:
        return base64.b64decode(out[0])
    except Exception:
        return None


def make_app_tile(app: Path, label: str) -> dict:
    """左侧 App 区的 App tile，字段结构照抄系统自己写的。"""
    guid = int.from_bytes(hashlib.md5(str(app).encode()).digest()[:4], "big") & 0x7FFFFFFF
    data = {
        "dock-extra": False,
        "file-data": {
            "_CFURLString": "file://" + urllib.parse.quote(str(app)) + "/",
            "_CFURLStringType": 15,
        },
        "file-label": label,
        "file-type": 41,
        "is-beta": False,
    }
    bid = bundle_id(app)
    if bid:
        data["bundle-identifier"] = bid
    book = bookmark_bytes(app)
    if book:
        data["book"] = book
    return {"GUID": guid, "tile-data": data, "tile-type": "file-tile"}


def build_launcher_app(g, style=DEFAULT_STYLE, force=False):
    """构建启动器 App：拼贴图标 + Swift 二进制 + Info.plist。

    返回 (app 路径, 有效 App 列表, 缺失列表)。内容运行时从分组文件夹现读，
    所以往文件夹里加/删 App 只需 rebuild 图标，不必重编译。
    """
    name = g["name"]
    folder = BASE / name
    _, mosaic, ok, missing = build_group(g, style=style)

    src = SCRIPT_DIR / "launcher/main.swift"
    app = APPS / f"{name}.app"
    exe = app / "Contents/MacOS/DockGroupLauncher"
    icon = app / "Contents/Resources/AppIcon.icns"
    info = app / "Contents/Info.plist"
    exe.parent.mkdir(parents=True, exist_ok=True)
    icon.parent.mkdir(parents=True, exist_ok=True)

    if force or not exe.exists() or src.stat().st_mtime > exe.stat().st_mtime:
        sh(["swiftc", "-swift-version", "5", "-O", "-o", str(exe),
            str(src), "-framework", "Cocoa"], check=True)
        sh(["chmod", "+x", str(exe)])

    plist = {
        "CFBundleExecutable": "DockGroupLauncher",
        "CFBundleIdentifier": (BUNDLE_PREFIX + "."
                               + hashlib.md5(name.encode()).hexdigest()[:10]),
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "12.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "DockGroupFolder": str(folder),
        "DockGroupName": name,
        "DockGroupLogDir": str(CACHE),
    }

    # 图标 / Info.plist / 签名只在内容真的变了才重写。
    # 每次重建都会改动 bundle 内容，LaunchServices 会因此作废该 App 的记录，
    # 之后再点就报「应用程序"X"已不能再打开」。内容没变就一个字节都别动。
    stamp = CACHE / f"{name}.bundle-stamp"
    digest = hashlib.sha256(
        plistlib.dumps(plist) + mosaic.read_bytes()).hexdigest()
    if force or not stamp.exists() or stamp.read_text().strip() != digest:
        png_to_icns(mosaic, icon)
        with info.open("wb") as f:
            plistlib.dump(plist, f)
        sh(["codesign", "--force", "--sign", "-", str(app)])
        stamp.write_text(digest)
        if Path(LSREGISTER).exists():
            sh([LSREGISTER, "-f", str(app)])
    return app, ok, missing


def tile_for(g) -> dict:
    """分组该用哪种 tile：右侧=文件夹 Stack，左侧=启动器 App。"""
    if g.get("placement", "left") == "right":
        return make_tile(BASE / g["name"], g["name"])
    return make_app_tile(APPS / f"{g['name']}.app", g["name"])


# ─────────────────────────────────────────────────────────── 分组文件夹（事实来源）

def read_folder_apps(folder: Path):
    """扫描分组文件夹 → [(显示名, 真实路径, 是否真别名)]，按名称排序。"""
    if not folder.is_dir():
        return []
    entries = sorted(
        (p for p in folder.iterdir()
         if p.name != ICON_ENTRY and not p.name.startswith(".")),
        key=lambda p: p.name.lower(),
    )
    if not entries:
        return []
    resolved = jxa("rdalias", *entries) or []
    out = []
    for i, p in enumerate(entries):
        target = Path(resolved[i]) if i < len(resolved) and resolved[i] else None
        if target is None or not target.exists():
            continue
        out.append((p.name, target, target != p))
    return out


def collect_apps(g, folder: Path, seed=True):
    """文件夹优先，为空时回落到配置里的 apps 列表。"""
    if seed:
        folder.mkdir(parents=True, exist_ok=True)
        # 别名已存在就跳过，全都存在时连 osascript 都不起
        todo = [Path(a).expanduser() for a in g.get("apps", [])
                if not (folder / Path(a).expanduser().stem).exists()]
        if todo:
            jxa("mkalias", folder, *todo)
    apps = read_folder_apps(folder)
    if apps:
        return apps
    return [(Path(a).expanduser().stem, Path(a).expanduser(), False)
            for a in g.get("apps", []) if Path(a).expanduser().exists()]


def build_group(g, icons_only=False, style=DEFAULT_STYLE):
    """返回 (folder, mosaic_png, 有效清单, 异常清单)。"""
    name = g["name"]
    folder = BASE / name
    apps = collect_apps(g, folder, seed=not icons_only)
    if not apps:
        raise SystemExit(f"分组「{name}」里没有任何 App")

    missing = [n for n, t, _ in apps if not t.exists()]
    ok = [(n, t, a) for n, t, a in apps if t.exists()]
    icon_paths = list(app_icons([t for _, t, _ in ok]).values())
    if not icon_paths:
        raise SystemExit(f"分组「{name}」未能提取到任何图标")

    mosaic = make_mosaic(icon_paths, CACHE / f"{name}.png", style=style)
    if not icons_only:
        set_folder_icon(folder, mosaic)
    return folder, mosaic, ok, missing


# ─────────────────────────────────────────────────────────── Dock 读写

_dock_cache = None


def dock_read(refresh: bool = False) -> dict:
    """读 Dock 配置。同一次命令里反复读没意义，缓存住；
    dock_write 会同步更新缓存，不会读到脏数据。"""
    global _dock_cache
    if _dock_cache is None or refresh:
        _dock_cache = plistlib.loads(sh(["defaults", "export", DOCK_DOMAIN, "-"]).stdout.encode())
    return _dock_cache


def dock_write(pl: dict):
    global _dock_cache
    data = plistlib.dumps(pl)
    BACKUP.mkdir(parents=True, exist_ok=True)
    (BACKUP / f"com.apple.dock-{datetime.now():%Y%m%d-%H%M%S}.plist").write_bytes(data)
    subprocess.run(["defaults", "import", DOCK_DOMAIN, "-"], input=data, check=True)
    _dock_cache = pl
    sh(["killall", "Dock"])


def tile_label(tile: dict):
    try:
        return tile["tile-data"]["file-label"]
    except Exception:
        return None


def tile_path(tile: dict):
    try:
        return urllib.parse.unquote(
            tile["tile-data"]["file-data"]["_CFURLString"]).replace("file://", "").rstrip("/")
    except Exception:
        return None


def make_tile(folder: Path, label: str) -> dict:
    return {
        "tile-data": {
            "arrangement": 1,          # 按名称排序
            "displayas": 0,            # 显示为文件夹 → 才会用自定义图标
            "dock-extra": False,
            "file-data": {
                "_CFURLString": "file://" + urllib.parse.quote(str(folder)) + "/",
                "_CFURLStringType": 15,
            },
            "file-label": label,
            "preferreditemsize": "-1",
            "showas": 2,               # 网格视图
        },
        "tile-type": "directory-tile",
    }


def _targets(cfg, only):
    return [g for g in cfg["groups"]
            if (only and g["name"] in only) or (not only and g.get("enabled", True))]


def _insert_after(tiles, tile, anchor_path):
    """把 tile 插到 anchor 对应条目之后；找不到锚点就追加到末尾。"""
    if anchor_path:
        for i, t in enumerate(tiles):
            if tile_path(t) == anchor_path:
                tiles.insert(i + 1, tile)
                return
    tiles.append(tile)


def dock_sync(cfg, only=None, prune=True):
    """把分组文件夹写进 Dock。

    位置策略：文件夹落在「被折叠的第一个 App 原来所在的位置」，不需手工配锚点。
    （macOS 不允许拖文件夹进左侧 App 区，但手写 plist 是能被 Dock 接受的，实测通过。）

    placement="left"  → 写进 persistent-apps（左侧 App 区）
    placement="right" → 写进 persistent-others（分隔线右侧）
    after=<App 路径>  → 可选，显式指定插在哪个 App 后面，覆盖自动落位
    """
    targets = _targets(cfg, only)
    pl = dock_read()
    managed = {g["name"] for g in cfg["groups"]}
    original = pl.get("persistent-apps", [])

    # 每组引用到的真实 App 路径
    paths_of = {}
    for g in targets:
        s = set()
        for _, t, _ in read_folder_apps(BASE / g["name"]):
            s.add(str(t))
            s.add(os.path.realpath(t))
        paths_of[g["name"]] = s
    all_grouped = set().union(*paths_of.values()) if paths_of else set()

    def matches(tile, pset):
        p = tile_path(tile)
        return bool(p) and (p in pset or os.path.realpath(p) in pset)

    # 自动落位：每组第一个 App 在原列表中的下标
    first_pos, fallback = {}, []
    for g in targets:
        idx = next((i for i, t in enumerate(original)
                    if matches(t, paths_of[g["name"]])), None)
        if idx is None:
            fallback.append(g)
        else:
            first_pos.setdefault(idx, []).append(g)

    def keep_left(t):
        if tile_label(t) in managed:
            return False
        return not (prune and matches(t, all_grouped))

    left = []
    for i, t in enumerate(original):
        for g in first_pos.get(i, []):
            if g.get("placement", "left") != "right":
                left.append(tile_for(g))
        if keep_left(t):
            left.append(t)

    right = [t for t in pl.get("persistent-others", [])
             if tile_label(t) not in managed
             and not (tile_path(t) or "").startswith(str(BASE))]

    for g in fallback:
        side = right if g.get("placement", "left") == "right" else left
        side.append(tile_for(g))

    # 显式 after 覆盖
    for g in targets:
        if not g.get("after"):
            continue
        left[:] = [t for t in left if tile_label(t) != g["name"]]
        _insert_after(left, tile_for(g), g["after"])

    pl["persistent-apps"] = left
    pl["persistent-others"] = right
    dock_write(pl)
    return [g["name"] for g in targets]


def dock_remove(names):
    pl = dock_read()
    pl["persistent-others"] = [t for t in pl.get("persistent-others", [])
                               if tile_label(t) not in set(names)]
    dock_write(pl)


def dock_has(label):
    pl = dock_read()
    for key in ("persistent-apps", "persistent-others"):
        if any(tile_label(t) == label for t in pl.get(key, [])):
            return True
    return False


# ─────────────────────────────────────────────────────────── App 发现

APP_DIRS = ("/Applications", "/System/Applications",
            "/Applications/Utilities", "/System/Applications/Utilities")


def dock_app_list():
    """当前 Dock 里所有 App 路径（保序去重）。"""
    out = []
    pl = dock_read()
    for key in ("persistent-apps", "persistent-others"):
        for t in pl.get(key, []):
            p = tile_path(t)
            if p and p.endswith(".app") and p not in out:
                out.append(p)
    return out


def resolve_app(spec: str):
    """把 'Google Chrome' / 'chrome' / 'Safari' / 完整路径 解析成 App 路径。"""
    p = Path(spec).expanduser()
    if p.exists():
        return p

    stem = spec[:-4] if spec.endswith(".app") else spec
    low = stem.lower()
    dirs = list(APP_DIRS) + [str(HOME / "Applications")]

    # ① 目录里精确匹配（拿到的 Path 大小写正确）
    for d in dirs:
        try:
            for e in sorted(Path(d).iterdir()):
                if e.suffix == ".app" and e.stem.lower() == low:
                    return e
        except OSError:
            continue

    # ② 交给 LaunchServices 按名字找（能覆盖 /System/Volumes/Preboot 里的 Safari 这类）
    r = sh(["osascript", "-l", "JavaScript", str(jxa_path("findapp")), stem])
    found = r.stdout.strip()
    if found and Path(found).exists():
        return Path(found)

    # ③ 最后退化成模糊匹配
    for d in dirs:
        try:
            for e in sorted(Path(d).iterdir()):
                if e.suffix == ".app" and low in e.stem.lower():
                    return e
        except OSError:
            continue
    return None


# ─────────────────────────────────────────────────────────── 子命令

def cmd_doctor(cfg, args):
    print(f"dockgroup {__version__}\n")

    def probe(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=30).returncode == 0
        except Exception:
            return False

    checks = [
        ("python3", "运行脚本本身", probe([sys.executable, "-c", "print(1)"])),
        ("Pillow", "合成拼贴图标 (PIL)", probe([sys.executable, "-c", "import PIL"])),
        ("osascript", "JXA 调 AppKit / Foundation", shutil.which("osascript") is not None),
        ("swiftc", "编译启动器 App（左侧模式）", shutil.which("swiftc") is not None),
        ("codesign", "App 临时签名", shutil.which("codesign") is not None),
        ("iconutil", "打包 .icns", shutil.which("iconutil") is not None),
        ("sips", "PNG 缩放", shutil.which("sips") is not None),
    ]
    allok = True
    for tool, why, good in checks:
        allok &= good
        print(f"  {'✅' if good else '❌'}  {tool:<10} {why}")

    print()
    print(f"  Python   : {sys.executable}  ({sys.version.split()[0]})")
    print(f"  落盘目录 : {BASE}")
    print(f"  配置文件 : {CONFIG_PATH if CONFIG_PATH.exists() else '（还没建，跑 init）'}")
    print(f"  依赖结论 : {'齐全，可以用了' if allok else '有缺失，见下'}")
    if not allok:
        print("\n  swiftc / codesign / iconutil / sips 都随 Xcode Command Line Tools 提供：")
        print("    xcode-select --install")
        print("  只想用右侧文件夹模式的话，缺 swiftc 也能跑（placement 设成 right）。")


def cmd_init(cfg, args):
    force = "--force" in args
    if CONFIG_PATH.exists() and not force:
        sys.exit(f"{CONFIG_PATH} 已存在（要覆盖请加 --force）")
    apps = dock_app_list()
    if not apps:
        sys.exit("读不到 Dock 里的 App，先确认 Dock 正常运行")
    name = "分组1"
    save_config({"style": DEFAULT_STYLE,
                 "groups": [{"name": name, "enabled": False,
                             "placement": "left", "apps": apps[:4]}]})
    print(f"已生成 {CONFIG_PATH}\n")
    print("你 Dock 里现有的 App（挑几个凑一组，改到配置的 apps 列表里）：")
    for i, a in enumerate(apps, 1):
        print(f"  {i:2}. {Path(a).stem}")
    print(f"\n配置里先放了一个示例分组「{name}」，enabled=false 不会被自动应用。")
    print(f"提示：也可以直接用 new 命令建组，不用手改 JSON：")
    print(f"  {SCRIPT_DIR / 'dockgroup.py'} new {name} \"WorkBuddy\" \"Google Chrome\"")


def cmd_new(cfg, args):
    args = [a for a in args if not a.startswith("--")]
    if len(args) < 2:
        sys.exit('用法：new <组名> "App 名或路径" ["更多 App"...]')
    gname, specs = args[0], args[1:]
    if find_group(cfg, gname):
        sys.exit(f"分组「{gname}」已存在，改配置或先 remove")
    paths, bad = [], []
    for s in specs:
        p = resolve_app(s)
        (paths if p else bad).append(p or s)
    if bad:
        sys.exit("找不到这些 App：" + "、".join(str(b) for b in bad))
    cfg.setdefault("groups", []).append({
        "name": gname, "enabled": False, "placement": "left",
        "apps": [str(p) for p in paths],
    })
    save_config(cfg)
    print(f"已添加分组「{gname}」（{len(paths)} 个 App）：")
    for p in paths:
        print(f"  · {p}")
    print(f"\n下一步：{SCRIPT_DIR / 'dockgroup.py'} preview {gname}   → 看图标")
    print(f"       {SCRIPT_DIR / 'dockgroup.py'} apply {gname}     → 写进 Dock")


def cmd_list(cfg, args):
    print(f"配置：{CONFIG_PATH}\n落盘：{BASE}\n")
    for g in cfg["groups"]:
        apps = read_folder_apps(BASE / g["name"])
        src = "文件夹"
        if not apps:
            src = "配置"
            apps = [(Path(a).expanduser().stem, Path(a).expanduser(), False)
                    for a in g.get("apps", [])]
        flag = "●" if g.get("enabled", True) else "○"
        print(f"  {flag} {g['name']:<10} {len(apps)} 个 App（来自{src}）"
              f"   {'Dock✓' if dock_has(g['name']) else 'Dock✗'}")
        for n, t, is_alias in apps:
            mark = "!" if not t.exists() else (" " if is_alias else "≠")
            print(f"      {mark} {n:<16} → {t}")
    print("\n  ● 启用   ○ 停用   ≠ 是真实 App 而非别名（建议换回别名）")


def cmd_preview(cfg, args):
    only = set(args) if args else None
    style = cfg.get("style", DEFAULT_STYLE)
    items = []
    # 不带参数时预览全部分组（预览是只读操作，不受 enabled 限制）
    for g in (cfg["groups"] if not only else [x for x in cfg["groups"] if x["name"] in only]):
        try:
            _, png, ok, _ = build_group(g, icons_only=True, style=style)
        except SystemExit as e:
            print(f"  跳过 {g['name']}：{e}")
            continue
        items.append((g["name"], png))
        print(f"  已合成 {g['name']}（{len(ok)} 个 App）")
    if not items:
        sys.exit("没有可预览的分组")
    CACHE.mkdir(parents=True, exist_ok=True)
    sheet = CACHE / "preview-all.png"
    make_contact_sheet(items, sheet)
    print(f"\n预览对比图：{sheet}")
    return sheet


def cmd_apply(cfg, args):
    keep = "--keep-originals" in args
    args = [a for a in args if not a.startswith("--")]
    only = set(args) if args else None
    targets = _targets(cfg, only)
    if not targets:
        sys.exit("没有匹配的分组")
    style = cfg.get("style", DEFAULT_STYLE)
    before = len(dock_read().get("persistent-apps", []))
    for g in targets:
        if g.get("placement", "left") == "right":
            dest, _, ok, missing = build_group(g, style=style)
        else:
            dest, ok, missing = build_launcher_app(g, style=style)
        print(f"  ✓ {g['name']} → {dest}（{len(ok)} 个 App）")
        if missing:
            print(f"       ⚠ 跳过 {len(missing)} 个不存在的 App")
    dock_sync(cfg, only=None, prune=not keep)
    after = len(dock_read().get("persistent-apps", []))
    print(f"\nDock 左侧 App 图标：{before} → {after}")
    for g in targets:
        pos = "左侧 App 区（%s 之后）" % Path(g["after"]).stem if g.get("after") \
            else ("分隔线右侧" if g.get("placement") == "right" else "左侧 App 区末尾")
        print(f"  分组「{g['name']}」位置：{pos}")
    print("备份在 ~/Dock Groups/.backup/，出错用 dockgroup.py restore 回滚")


def cmd_rebuild(cfg, args):
    quiet = "--quiet" in args
    guard = CACHE / ".last-build"
    if quiet and guard.exists() and time.time() - guard.stat().st_mtime < 4:
        return   # 防监听自触发死循环
    touched = []
    style = cfg.get("style", DEFAULT_STYLE)
    for g in cfg["groups"]:
        if not (BASE / g["name"]).is_dir():
            continue
        try:
            if g.get("placement", "left") == "right":
                build_group(g, style=style)
            else:
                build_launcher_app(g, style=style)
            touched.append(g["name"])
        except SystemExit as e:
            if not quiet:
                print(f"  跳过 {g['name']}：{e}")
    CACHE.mkdir(parents=True, exist_ok=True)
    guard.write_text(str(time.time()))
    if touched:
        sh(["killall", "Dock"])
        sh(["killall", "Finder"])
    if not quiet:
        print(f"已刷新：{', '.join(touched) if touched else '无'}（Dock 已重启）")


def cmd_open(cfg, args):
    if not args:
        sys.exit("请指定分组名")
    g = find_group(cfg, args[0])
    if not g:
        sys.exit(f"没有分组「{args[0]}」")
    folder = BASE / g["name"]
    folder.mkdir(parents=True, exist_ok=True)
    sh(["open", str(folder)])
    print(f"已打开 {folder}")
    print("往里加 App：按住 ⌘ ⌥ 从「应用程序」拖进来 = 建别名（不会移动原 App）")
    print("加完跑一次：dockgroup.py rebuild")


def cmd_remove(cfg, args):
    if not args:
        sys.exit("请指定要移除的分组名")
    dock_remove(args)
    print(f"已从 Dock 移除：{', '.join(args)}（文件夹保留）")


def cmd_clean(cfg, args):
    if not args:
        sys.exit("请指定要清理的分组名")
    dock_remove(args)
    for n in args:
        f = BASE / n
        if f.exists():
            shutil.rmtree(f)
    print(f"已从 Dock 移除并删除文件夹：{', '.join(args)}")


def cmd_watch_install(cfg, args):
    AGENT_PLIST.parent.mkdir(parents=True, exist_ok=True)
    AGENT_PLIST.write_bytes(plistlib.dumps({
        "Label": AGENT_LABEL,
        "ProgramArguments": ["/usr/bin/python3", str(SCRIPT_DIR / "dockgroup.py"),
                             "rebuild", "--quiet"],
        "WatchPaths": [str(BASE / g["name"]) for g in cfg["groups"]],
        "RunAtLoad": False,
        "ThrottleInterval": 5,
    }))
    domain = f"gui/{uid()}"
    subprocess.run(f"launchctl bootout {domain} {AGENT_PLIST} >/dev/null 2>&1", shell=True)
    r = subprocess.run(f"launchctl bootstrap {domain} {AGENT_PLIST}",
                       shell=True, capture_output=True, text=True)
    if r.returncode == 0:
        print(f"已写入并启用 {AGENT_PLIST}")
        print("自动监听生效：往分组文件夹里加/删 App，图标会自动更新。")
    else:
        print(f"已写入 {AGENT_PLIST}")
        print("但当前进程没有 launchd 权限，无法自动加载。请在你自己的「终端」里执行一次：")
        print(f"  launchctl bootstrap {domain} {AGENT_PLIST}")
    print("注：之后新增分组文件夹，需要重新跑一次 watch-install 才会被监听。")


def cmd_watch_uninstall(cfg, args):
    subprocess.run(f"launchctl bootout gui/{uid()} {AGENT_PLIST}", shell=True,
                   capture_output=True, text=True)
    AGENT_PLIST.unlink(missing_ok=True)
    print("自动监听已卸载")


def cmd_test(cfg, args):
    if not args:
        sys.exit("请指定分组名")
    g = find_group(cfg, args[0])
    if not g:
        sys.exit(f"没有分组「{args[0]}」")
    if g.get("placement", "left") == "right":
        sys.exit("该分组用文件夹 Stack 模式，直接在 Dock 里点就行")
    app = APPS / f"{g['name']}.app"
    if not app.exists():
        sys.exit(f"启动器还没构建：{app}，先跑一次 apply")
    sh(["open", str(app)])
    print(f"已启动 {app}")
    print(f"运行日志：{CACHE / (g['name'] + '.launch.log')}")


def cmd_logs(cfg, args):
    """查看某个分组的运行日志：面板几何 + 点击事件轨迹。"""
    if not args:
        sys.exit("用法：logs <组名>")
    g = find_group(cfg, args[0])
    if not g:
        sys.exit(f"没有分组「{args[0]}」")
    name = g["name"]
    state, events = CACHE / f"{name}.launch.log", CACHE / f"{name}.events.log"

    if state.exists():
        print("— 面板几何（最近一次弹出）—")
        for line in state.read_text(encoding="utf-8").splitlines():
            print("  " + line)
        print()
    if events.exists():
        lines = events.read_text(encoding="utf-8", errors="replace").splitlines()
        print(f"— 事件轨迹（最后 {min(40, len(lines))} 行，共 {len(lines)} 行）—")
        for line in lines[-40:]:
            print("  " + line)
        print()
        print("  排查提示：")
        print("   · 只有 === launch，没有 mouseDown hit item  → 点击没送达视图（窗口层级/事件路由问题）")
        print("   · 有 mouseDown 但没有 launching            → 命中下标不对，目标路径有问题")
        print("   · 有 launching 但 openApplication 报错      → LaunchServices 拒绝启动")
        print("   · 出现 dismiss: click outside panel        → 被误判成点了面板外")
    else:
        print(f"还没有事件日志：{events}")
        print("去点一次 Dock 上的分组图标，再跑这个命令。")


def cmd_restore(cfg, args):
    if args:
        src = Path(args[0])
    else:
        cands = sorted(BACKUP.glob("com.apple.dock-*.plist"))
        if not cands:
            sys.exit("没有可用备份")
        src = cands[-1]
    data = src.read_bytes()
    plistlib.loads(data)
    subprocess.run(["defaults", "import", DOCK_DOMAIN, "-"], input=data, check=True)
    sh(["killall", "Dock"])
    print(f"已从 {src} 恢复 Dock")


def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        return
    if argv[0] in ("-v", "--version", "version"):
        print(f"dockgroup {__version__}")
        return
    cmd, args = argv[0], argv[1:]
    table = {
        "doctor": cmd_doctor, "init": cmd_init, "new": cmd_new,
        "list": cmd_list, "preview": cmd_preview, "apply": cmd_apply,
        "rebuild": cmd_rebuild, "open": cmd_open, "test": cmd_test, "logs": cmd_logs, "logs": cmd_logs,
        "remove": cmd_remove, "clean": cmd_clean,
        "watch-install": cmd_watch_install,
        "watch-uninstall": cmd_watch_uninstall, "restore": cmd_restore,
    }
    if cmd not in table:
        sys.exit(f"未知命令：{cmd}\n\n{__doc__}")
    table[cmd](load_config(), args)


if __name__ == "__main__":
    main()
