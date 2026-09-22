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
日常最常用的四条 —— 都会自动刷新图标并重启 Dock，不需要再跑别的命令：

    add     组名 "App" ...   往分组里加 App（App 名支持模糊匹配）
    del     组名 "App" ...   从分组里删 App（同样支持模糊匹配）
    new     组名 "App" ...   新建分组
    apply   [组名...]        写进 Dock（不填 = 全部启用中的分组）

不想记组名、不想拼 App 名时，add / new 不带参数直接进交互引导：

    add     （无参数）        列出分组 → 输关键词过滤 App → 敲数字多选 → 回车搞定
    new     （无参数）        输组名 → 多选 App → 建完问你要不要直接写进 Dock
    new --apply 组名 "App".. 新建分组并一步写进 Dock

其余：

    dg                    不带参数 = 显示帮助 + 当前分组状态
    list                  查看配置与 Dock 当前状态
    preview [组名...]     预览拼贴图标，不改动 Dock
    rebuild [--quiet]     全部重新生成图标并重启 Dock
    style [组名|--all] [材质]   换面板底色（不带参数 = 看现状 + 材质清单）
    open    组名          在 Finder 里打开分组文件夹（拖 App 进去）
    test    组名          手动启动一次启动器，验证点击展开效果
    logs    组名          查看运行日志（面板几何 + 点击事件轨迹）
    remove  组名...       从 Dock 移除（保留文件夹）
    clean   组名...       从 Dock 移除并删除文件夹
    doctor                体检：检查依赖是否齐全
    init [--force]        扫描当前 Dock，生成 starter groups.json
    watch-install         安装自动监听（文件夹一变就自动刷新图标）
    watch-uninstall       卸载自动监听
    restore [备份]        从最近一次备份恢复 Dock
    gui [--rebuild]       打开图形界面（分组管理窗口）

apply 可选：--keep-originals 保留左侧原图标，不自动摘除。

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
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

__version__ = "1.3.0"

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    # 这条文案以前写的是「请用 /usr/bin/python3 运行（系统自带 PIL）」——错的。
    # Pillow 不在 macOS 自带依赖里，得用户自己 pip 装；而报错时用户用的
    # 恰恰就是 /usr/bin/python3，被告知「你解释器用错了」只会更懵。
    sys.exit(
        "缺少 Pillow（PIL）—— 它不在 macOS 自带依赖里，需要自己装：\n"
        "\n"
        "    /usr/bin/python3 -m pip install --user Pillow\n"
        "\n"
        f"当前解释器：{sys.executable}\n"
        "装完直接重跑即可。必须装给 /usr/bin/python3：Pillow 会落到它的 user site\n"
        "目录，换成 Homebrew / venv 的 Python 读不到这份包。"
    )

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


def engine_command() -> str:
    """生成 .app 的 Info.plist 里 DockGroupScript 该写的引擎入口。

    优先用户级的 dg 短命令（Swift 版二进制或它的 shim 都能被直接 exec），
    没有就退回仓库里的 dockgroup.py。这个路径跨引擎切换是**稳定**的：
    install.command 把 ~/.local/bin/dg 从 Python shim 换成 Swift 二进制后，
    旧 .app 无需重建就会自动用上新引擎。两套实现（Python / Swift）的
    engine_command 必须解析出**同一个路径**，对照测试比的就是这个。
    """
    dg = HOME / ".local" / "bin" / "dg"
    if dg.is_file() and os.access(dg, os.X_OK):
        return str(dg)
    return str(SCRIPT_DIR / "dockgroup.py")

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
        bg=((225, 227, 234, 252), (198, 201, 213, 253)),
        hair=(255, 255, 255, 200), edge=((122, 126, 141, 135), 0.0025),
        cell=0.440, pad=0.085, gap=0.045, shadow=True, icon_shadow=True),
    # 比 dock 再深一档，白图标对比更强
    "dock-deep": dict(
        bg=((209, 212, 221, 252), (176, 180, 194, 253)),
        hair=(255, 255, 255, 205), edge=((104, 108, 124, 150), 0.0025),
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
DEFAULT_STYLE = "graphite"
# 默认面板材质。
#
# 为什么默认不是 menu（最像 Dock 栏的浅灰玻璃）：实测下来，很多 App 的图标
# 本身就是「白底圆角卡片」（DSH Desktop / Hermes / 备忘录 …），放在浅色玻璃上
# 边界直接糊进背景，图标认不出来。深色玻璃上这些白底图标反而最清楚，
# 整体观感也更接近系统 Dock 文件夹展开的效果。想换回浅色：dg style --all menu
DEFAULT_MATERIAL = "hud"

# 面板毛玻璃材质。key 必须和启动器 main.swift 里 material(named:) 的分支一一对应，
# 对不上会静默退回 .menu —— 加了新分支记得两边一起改。
MATERIALS = {
    "hud":               "深色玻璃（当前默认）。白底 App 图标在浅色底上会和背景糊在一起，用这个最清楚",
    "menu":              "半透明灰玻璃，最接近 Dock 栏的质感",
    "popover":           "接近纯白（系统 popover 的底色）",
    "toolTip":           "深色提示框，比 hud 淡一点",
    "sidebar":           "侧边栏材质",
    "header":            "表头材质",
    "titlebar":          "标题栏材质",
    "underWindow":       "窗口背景之下",
    "contentBackground": "内容背景",
    "sheet":             "表单材质",
    "windowBackground":  "窗口背景色",
    "appearanceBased":   "跟随系统外观（老的 appearanceBased 行为）",
    "fullScreenUI":      "全屏 UI 材质",
}

# 弹出面板的网格布局。
#
# 默认是 row（长条）—— 这是最早的行为，也是观感上更贴合 Dock 的一条横带。
# auto（按应用数排四宫格 / 九宫格）是**可选项**，用 `dg layout --all auto` 开。
#
# dock / dock-name 是「和 Dock 条等高」的两档（2026-09-20 加）：
# 现场量出来 Dock 条高 72pt，而原来的长条面板高 132pt，弹出来比 Dock 高出一大截。
#   dock       面板 = Dock 条高（72），图标撑满、不画名字（悬停出系统提示）
#   dock-name  面板 = Dock 条高 + 8（80），图标缩到 42 = Dock 图标真实大小，名字照常显示
#
# dock-grid 是 dock 系的第三档「无字网格」（2026-09-20 加）：格子规格和 dock 同源
# （图标 44 = Dock 图标同档、同样不画名字），但按网格排。设计目标是**两行时面板高
# 正好等于 Dock 条的两倍**，于是 2×2 四宫格 = 144×144 —— 既是 72×2，又天然是正方形。
# 推导：2*bar = pad*2 + 2*cell + gap  →  cell = bar - pad - gap/2。
# 行数再多高度按行数线性涨（5~6 个 → 3×2 = 205×144），这是「和 Dock 成整数倍」的自然
# 延伸。它和 auto 的分工：auto 是独立的大格子（100）+ 名字，完全不看 Dock 尺寸。
#
# 历史：列数原来是 `min(kMaxCols, n)`，n ≤ 4 时列数恒等于 n、行数恒为 1 —— 所以
# 3~4 个 App 的分组点开永远只有一条长条。现在 row 模式字面上就是这个旧行为，
# auto 模式才按应用数推导列数。
DEFAULT_LAYOUT = "row"
LAYOUTS = {
    "row":  "长条（当前默认）。能铺一行就铺一行，超过 4 个按 4 列换行",
    "auto": "自适应网格。1→1×1，2→2×1，3~4→2×2 四宫格，"
            "5~6→3×2，7~9→3×3 九宫格，≥10→4 列",
    "dock": "和 Dock 条等高（72）。图标 44 = Dock 图标同大，不画名字（悬停出系统提示）；"
            "4 个 App 是 242×72，弹在 Dock 上像同一条栏的延续",
    "dock-name": "和 Dock 条等高，另让 8pt 给名字（80）。图标 42 = Dock 图标真实大小；"
                 "4 个 App 是 378×80",
    "dock-grid": "和 Dock 条两倍等高 · 无字网格。格子与 dock 同源（图标 44、不画名字），"
                 "两行时面板高 = 条高 ×2；3~4 个 App 是 144×144（同时也是正方形）",
    "2":    "固定 2 列",
    "3":    "固定 3 列",
    "4":    "固定 4 列",
}

# 列数上限，必须和 main.swift 的 kMaxCols 保持一致。
MAX_COLS = 4

# 格子尺寸，必须和 main.swift 的 kCellW / kCellH / kCellWGrid 保持一致。
CELL_W_ROW, CELL_H, CELL_W_GRID, CELL_PAD, CELL_GAP = 86, 100, 100, 16, 7

# Dock 条默认高度 / dock 系的格子内边距与间距，必须和 main.swift 的
# dockBarHeight() / geometry(for:) 一致。Swift 那侧是按「屏幕可用区 - 8」实时算的
# （本机 = 72）；这里拿不到屏幕尺寸，只能用同一个默认值做**预览**估算 ——
# 用户在 Dock 设置里改过图标大小的话，这里显示的尺寸会和真机略有出入。
#
# dock 的留白取 14：图标 = 72 - 28 = 44，正好和 Dock 图标（实测 42.5）同档，
# 上下留白也和 Dock 条自己的节奏一样，所以两者能连成一条。
DOCK_BAR_DEFAULT = 72
DOCK_PAD, DOCK_GAP = 14, 6
DOCK_NAME_PAD = 8               # dock-name 另算：要让出 8pt 给名字


def panel_geom(mode):
    """该布局的 (格子宽, 格子高, 内边距, 间距)。

    ⚠️ 必须和 main.swift 的 geometry(for:) 一一对应 —— 改一边就要改另一边。

    长条模式 86 宽（横向排开更紧凑）；网格模式 100 宽，与格子高度相等 —— 格子方了，
    n×n 的面板才是正方形。之前网格也沿用 86，2×2 就成了 211×239 的竖长方形。

    dock 系三档另外算：dock / dock-name 按 Dock 条高推（见常量区的注释），
    dock-grid 取正方格子 55（= bar - pad - gap/2），于是两行时面板高正好是条高的两倍。
    """
    m = str(mode).strip().lower()
    if m in ("dock", "dock-name"):
        if m == "dock":
            icon = DOCK_BAR_DEFAULT - DOCK_PAD * 2          # 44 = Dock 图标同档
            return icon + 8, icon, DOCK_PAD, DOCK_GAP
        return (CELL_W_ROW, DOCK_BAR_DEFAULT - DOCK_NAME_PAD * 2 + 8,
                DOCK_NAME_PAD, DOCK_GAP)
    if m == "dock-grid":
        # 格子取正方，且让「两行 = 两倍条高」成立：
        #   2*bar = pad*2 + 2*cell + gap  →  cell = bar - pad - gap/2 = 55（bar=72）
        # 于是 2×2 是 144×144 —— 既是 72×2 又正好是正方形。
        cell = int(DOCK_BAR_DEFAULT - DOCK_PAD - DOCK_GAP / 2)
        return cell, cell, DOCK_PAD, DOCK_GAP
    return (CELL_W_ROW if m == "row" else CELL_W_GRID), CELL_H, CELL_PAD, CELL_GAP


def cell_w_for(mode):
    """该布局的格子宽度。只是 panel_geom() 的便捷读法，保留给 `tools/readme_assets.py`
    这类老调用方 —— 几何规则只有 panel_geom() 一份，别在这儿再写一套。"""
    return panel_geom(mode)[0]


def layout_grid(mode, n):
    """按布局模式算 (列数, 行数)。

    ⚠️ 这段必须和 main.swift 的 columns(for:layout:) 逐条对应 —— 改一边就要改另一边。
    这里只用于在 `dg layout` 里预览「这个分组会变成几宫格」，真正画面板的是 Swift 那侧。
    """
    n = max(int(n), 1)
    mode = str(mode).strip().lower()
    if mode.isdigit() and int(mode) > 0:
        cols = min(int(mode), n)
    elif mode in ("row", "dock", "dock-name"):
        cols = min(MAX_COLS, n)             # dock 系共用长条的单行行为
    else:                               # auto，也是未知取值的兜底
        if n <= 2:
            cols = n                    # 1→1×1，2→2×1
        elif n <= 4:
            cols = 2                    # 四宫格
        elif n <= 9:
            cols = 3                    # 3×2 或九宫格
        else:
            cols = MAX_COLS
        cols = min(min(cols, n), MAX_COLS)
    return max(cols, 1), -(-n // max(cols, 1))


def panel_size(mode, n):
    """按布局模式算面板的 (宽, 高)。

    ⚠️ 和 main.swift 的 PanelGeometry.panelSize(cols:rows:) 是同一套算法。
    """
    cols, rows = layout_grid(mode, n)
    cw, ch, pad, gap = panel_geom(mode)
    return (pad * 2 + cols * cw + (cols - 1) * gap,
            pad * 2 + rows * ch + (rows - 1) * gap)

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
    """跑外部命令。

    找不到可执行文件时**不抛异常**，返回一个 returncode=-1 的结果就行 ——
    `dg doctor` 这类诊断路径恰恰是在「环境不对劲」的时候跑的，它自己不能
    因为环境不对就先崩掉。（实测：PATH 异常时 `security find-identity`
    直接把 doctor 打挂，用户想看诊断信息反而什么都看不到。）
    """
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=check)
    except FileNotFoundError:
        return subprocess.CompletedProcess(
            cmd, returncode=-1, stdout="", stderr=f"找不到可执行文件：{cmd[0]}")


def uid() -> str:
    return subprocess.run(["id", "-u"], capture_output=True, text=True).stdout.strip()


# ─────────────────────────────────────────────────────────── 隔离属性
#
# com.apple.quarantine 只在「从网络下载」时被打上：浏览器、邮件、AirDrop、
# 下载的 zip 解压后、从网络卷拷来的文件。本地创建的文件永远没有 ——
# 所以在开发机上怎么测都复现不了，只有真的发出去才炸。
#
# 它和签名是两回事：带 quarantine 的 app 即使签名完整，首次打开也会被
# Gatekeeper 拦下来报「无法验证开发者」。用户看到这句会以为签名坏了，
# 其实只要把属性清掉就能开。

def quarantine_listing(path) -> str:
    """递归列出整棵目录树上的扩展属性，用来判断有没有隔离标记。"""
    r = sh(["xattr", "-r", "-l", str(path)])
    return r.stdout or ""


def has_quarantine(path) -> bool:
    p = Path(path)
    return p.exists() and "com.apple.quarantine" in quarantine_listing(p)


def kill_launchers() -> bool:
    """结束正在运行的启动器实例，返回是否真杀到了。

    **为什么每次重建之后都必须做这一步**：启动器是常驻一小段时间的进程 ——
    面板收起后还要活 kIdleSeconds 秒才退（见 launcher/main.swift 的注释：立刻退出
    会让 Dock 报「应用程序"X"已不能再打开」）。而它的面板几何、材质、成员清单都是
    **进程启动时**从 Info.plist 读进内存的，之后你就是把 bundle 重建十遍也影响不到
    那个已经在跑的进程 —— 你点 Dock 图标时 LaunchServices 走的是 reopen，还是回到
    它，于是面板维持旧样子。

    实测踩过（2026-09-20，用户报「选了自适应网格后无反应」）：全局 layout 从 dock
    改成 auto，groups.json 和 AI.app/Contents/Info.plist 里都已经是 auto，apply 也
    确实重建了 bundle，但点开面板仍是 242×69 的 dock 条。同一个 cache 目录里
    「浏览器」组却是新的 211×239 —— 区别只在于它那个旧进程已经自己退出了。

    杀干净之后下次点击会启动新进程、读新 bundle。那 0.4 秒是为了等 LaunchServices
    消化进程退出，否则紧接着点击可能撞上「已不能再打开」。

    设了 DOCKGROUP_DOCK_PLIST（对照测试模式）时直接返回 False、不动任何进程 ——
    否则跑一次对照测试会把你自己开着的面板全关掉。
    """
    if dock_plist_override() is not None:
        return False
    r = sh(["pkill", "-f", "DockGroupLauncher"])
    if r.returncode == 0:
        time.sleep(0.4)
        return True
    return False


def strip_quarantine(path) -> bool:
    """清掉整棵目录树上的隔离属性，返回是否真的清过。

    为什么构建完必须做：产物要能脱离「我这台机器」运行。三条路都会带进来 ——
      ① 下载 release zip 解压：源码带隔离，生成的 .app 会继承；
      ② 用 Safari / 邮件收到别人打包的 .app：直接带；
      ③ 从 U 盘、网络卷、共享目录拷过来的仓库。

    `xattr -cr` 递归清，属性不存在也不报错。
    """
    p = Path(path)
    if not p.exists():
        return False
    if "com.apple.quarantine" not in quarantine_listing(p):
        return False
    sh(["xattr", "-cr", str(p)])
    return True


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


def _panel_base(S, st):
    """画图标底板：投影 + 渐变 + 内圈高光 + 外圈描边。

    返回 (canvas, box, side)。拼贴图标和管理窗口图标共用这一份 —— 两边的底板
    必须逐像素一致，并排出现在 Dock 里才像一家人。

    抽出来的原因：2026-09-20 加管理窗口图标时，我照着 make_mosaic 另抄了一段，
    漏掉了 ICON_INSET（底板只占 85% 边长，不是铺满），结果底板比分组图标大一圈、
    圆角也对不上。这类几何常量只要允许抄第二遍，就一定会漂。
    """
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

    return canvas, box, side


def make_mosaic(icon_paths, out, size: int = 1024,
                style: str = DEFAULT_STYLE) -> Path:
    """把若干 App 图标合成一张 iOS 风格的文件夹图标。"""
    out = Path(out)
    S = size
    st = STYLES.get(style, STYLES[DEFAULT_STYLE])
    canvas, box, side = _panel_base(S, st)
    inset = box[0]

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


def launcher_binary(force=False) -> Path:
    """编译启动器二进制 —— 所有分组共用同一份。

    为什么不能靠 mtime 判断要不要重编译：`codesign --force --sign -` 会把签名
    写进 Mach-O（__LINKEDIT），**改动可执行文件本身**，于是它的 mtime 永远比
    main.swift 新。原来那句 `src.mtime > exe.mtime` 因此在第一次签名之后就永久
    失效 —— 改完 main.swift 跑 rebuild 不会重编译，Dock 上点开看到的还是旧面板，
    而 rebuild 照样打印「已刷新」。改这个文件时踩过：UI 改动"没生效"，查了半天
    怀疑是材质和圆角，实际是二进制压根没换。所以改用 main.swift 的**内容摘要**
    当判据，戳另存一份，跟被签名的产物彻底解耦。

    另外启动器需要的全部信息（分组名、文件夹、材质、脚本路径）都写在
    Info.plist 里，二进制本身与分组无关 —— 一份编译产物给所有分组用，
    rebuild 少编译 N-1 次。
    """
    # 源码查找：仓库优先，缓存兜底（预编译安装时 install.command 会把副本
    # 放进缓存，内容与摘要戳同源 —— 仓库被删/挪后摘要照样命中缓存）。
    src = SCRIPT_DIR / "launcher/main.swift"
    if not src.exists():
        src = CACHE / ".launcher.main.swift"
    if not src.exists():
        raise SystemExit(
            f"找不到启动器源码：{SCRIPT_DIR / 'launcher/main.swift'}\n"
            "（仓库被移动或删除了？重跑一次 tools/install.command 可修复）")
    cached = CACHE / ".launcher.bin"
    stamp = CACHE / ".launcher.src-stamp"
    digest = hashlib.sha256(src.read_bytes()).hexdigest()
    if (not force and cached.exists() and stamp.exists()
            and stamp.read_text().strip() == digest):
        return cached
    CACHE.mkdir(parents=True, exist_ok=True)
    sh(["swiftc", "-swift-version", "5", "-O", "-o", str(cached),
        str(src), "-framework", "Cocoa"], check=True)
    sh(["chmod", "+x", str(cached)])
    stamp.write_text(digest)
    return cached


def build_launcher_app(g, style=DEFAULT_STYLE, force=False,
                       material=DEFAULT_MATERIAL, layout=DEFAULT_LAYOUT, seed=None):
    """构建启动器 App：拼贴图标 + Swift 二进制 + Info.plist。

    返回 (app 路径, 有效 App 列表, 缺失列表)。内容运行时从分组文件夹现读，
    所以往文件夹里加/删 App 只需 rebuild 图标，不必重编译。
    """
    name = g["name"]
    folder = BASE / name
    _, mosaic, ok, missing = build_group(g, style=style, seed=seed)

    binary = launcher_binary(force=force)
    app = APPS / f"{name}.app"
    exe = app / "Contents/MacOS/DockGroupLauncher"
    icon = app / "Contents/Resources/AppIcon.icns"
    info = app / "Contents/Info.plist"
    exe.parent.mkdir(parents=True, exist_ok=True)
    icon.parent.mkdir(parents=True, exist_ok=True)

    plist = {
        "CFBundleExecutable": "DockGroupLauncher",
        "CFBundleIdentifier": (BUNDLE_PREFIX + "."
                               + hashlib.md5(name.encode()).hexdigest()[:10]),
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "placeholder",   # 下面按内容摘要填，变了才让 Dock 刷图标
        "LSMinimumSystemVersion": "12.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "DockGroupFolder": str(folder),
        "DockGroupName": name,
        "DockGroupLogDir": str(CACHE),
        "DockGroupMaterial": material,
        # 网格布局模式（auto / row / 数字）。启动器按它决定列数，
        # 见 main.swift 的 columns(for:layout:)。进内容摘要 → 改了会重写 bundle。
        "DockGroupLayout": str(layout),
        # 启动器收到拖放后要回调引擎；GUI 进程的 PATH 只有 /usr/bin:/bin，
        # 不能指望 dg 在 PATH 里，直接把绝对路径塞进去。
        "DockGroupScript": engine_command(),
        # 声明能处理 .app → 拖 App 到 Dock 图标上时 tile 会高亮成放置目标。
        # LSHandlerRank=Alternate：不当默认处理器（双击 App 仍由系统启动），
        # 只作为「可以接收」的候选，保证 Dock 拖放会高亮。
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "Application",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["com.apple.application",
                                   "com.apple.application-bundle"],
        }],
    }

    # 图标 / Info.plist / 签名只在内容真的变了才重写。
    # 每次重建都会改动 bundle 内容，LaunchServices 会因此作废该 App 的记录，
    # 之后再点就报「应用程序"X"已不能再打开」。内容没变就一个字节都别动。
    #
    # 但反过来有个坑：bundle 路径和 CFBundleVersion 都不变时，
    # IconServices 会一直用旧图标缓存 —— 我们这边换了灰底，Dock 还显示旧的白底。
    # 所以让 CFBundleVersion 跟着内容摘要走：图标一变版本号就变，Dock 才会刷新。
    #
    # 二进制也进摘要：main.swift 一改，摘要就变，于是必然会重写 exe 并重新签名 ——
    # 否则会出现「源码变了、戳没变」，拷贝那一步被跳过，App 里还是旧二进制。
    core = {k: v for k, v in plist.items() if k != "CFBundleVersion"}
    digest = hashlib.sha256(
        plistlib.dumps(core) + mosaic.read_bytes()
        + binary.read_bytes()).hexdigest()
    plist["CFBundleVersion"] = digest[:8]
    plist["CFBundleShortVersionString"] = "1.0." + digest[:6]

    stamp = CACHE / f"{name}.bundle-stamp"
    if (force or not exe.exists() or not stamp.exists()
            or stamp.read_text().strip() != digest):
        # 覆盖 exe 必须在签名之前：改了 bundle 内容不重签，macOS 会拒绝启动。
        shutil.copyfile(binary, exe)
        os.chmod(exe, 0o755)
        png_to_icns(mosaic, icon)
        with info.open("wb") as f:
            plistlib.dump(plist, f)
        sh(["codesign", "--force", "--sign", "-", str(app)])
        stamp.write_text(digest)
        if Path(LSREGISTER).exists():
            sh([LSREGISTER, "-f", str(app)])
        # 关键：IconServices 按 bundle 的 mtime 缓存图标。
        # 原地改内容而不改 mtime，Dock 会一直显示旧图标（实测踩过）。
        for d_ in (app, app / "Contents", app / "Contents/Resources", icon):
            try:
                os.utime(d_, None)
            except OSError:
                pass
    # 最后统一清一次隔离属性 —— 产物要能脱离「我这台机器」。
    # 放在签名之后是安全的：quarantine 不在 codesign 的保护范围内，
    # 清它不会让签名失效。（真正影响签名的是文件内容，那些我们不碰。）
    if strip_quarantine(app):
        print(f"  已清除「{app.name}」继承来的隔离属性"
              "（否则首次打开会被 Gatekeeper 拦）")
    return app, ok, missing


MANAGER_SRC = "manager/main.swift"


def manager_binary(force=False) -> Path:
    """编译管理窗口二进制。判据和 launcher_binary 一致：按源码内容摘要，
    不看 mtime —— codesign 会把签名写进可执行文件，mtime 判据必然失效。
    """
    # 缓存兜底同 launcher_binary，见那里的注释。
    src = SCRIPT_DIR / MANAGER_SRC
    if not src.exists():
        src = CACHE / ".manager.main.swift"
    if not src.exists():
        raise SystemExit(
            f"找不到管理窗口源码：{SCRIPT_DIR / MANAGER_SRC}\n"
            "（仓库被移动或删除了？重跑一次 tools/install.command 可修复）")
    cached = CACHE / ".manager.bin"
    stamp = CACHE / ".manager.src-stamp"
    digest = hashlib.sha256(src.read_bytes()).hexdigest()
    if (not force and cached.exists() and stamp.exists()
            and stamp.read_text().strip() == digest):
        return cached
    CACHE.mkdir(parents=True, exist_ok=True)
    # -parse-as-library：SwiftUI 的 @main 不能和顶层代码共存，不加这个
    # 编译直接报「'main' attribute cannot be used in a module that contains
    # top-level code」。
    sh(["swiftc", "-swift-version", "5", "-parse-as-library", "-O",
        "-o", str(cached), str(src),
        "-framework", "SwiftUI", "-framework", "Cocoa"], check=True)
    sh(["chmod", "+x", str(cached)])
    stamp.write_text(digest)
    return cached


def make_manager_icon(out: Path) -> Path:
    """画管理窗口的 Dock 图标。

    为什么不复用分组的拼贴图：拼贴图表达的是「某个分组里有什么」，而管理窗口管的是
    全部分组 —— 拿其中一个分组的样子当门面会误导。这里画抽象版：graphite 底板 +
    2×2 格子，和分组图标同一套视觉语言，内容中性。

    右下那一格用强调色（其余白色），是为了在 Dock 里一眼和分组图标区分开 ——
    两者底色和圆角都一样，纯靠格子颜色分辨。
    """
    S = 1024
    st = STYLES[DEFAULT_STYLE]
    canvas, box, side = _panel_base(S, st)
    inset = box[0]

    pad, gap = int(side * st["pad"]), int(side * st["gap"])
    cell = (side - 2 * pad - gap) // 2
    d = ImageDraw.Draw(canvas)
    for r in range(2):
        for c in range(2):
            x = inset + pad + c * (cell + gap)
            y = inset + pad + r * (cell + gap)
            fill = (55, 138, 221, 250) if (r, c) == (1, 1) else (255, 255, 255, 234)
            d.rounded_rectangle((x, y, x + cell - 1, y + cell - 1),
                                radius=int(cell * 0.16), fill=fill)
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out)
    return out


def build_manager_app(force=False) -> Path:
    """打包管理窗口 App —— 全机只有一个，不随分组变化。

    和 build_launcher_app 的差别：这是有 Dock 图标、能被双击的普通 App，
    所以不设 LSUIElement。

    DockGroupScript 必须写绝对路径：GUI 进程的 PATH 只有 /usr/bin:/bin，
    里面也没有 dg 这个短命令，只能靠 Info.plist 把引擎位置告诉它。
    """
    binary = manager_binary(force=force)
    app = APPS / "DockGroup.app"
    exe = app / "Contents/MacOS/DockGroupManager"
    icon = app / "Contents/Resources/AppIcon.icns"
    info = app / "Contents/Info.plist"
    exe.parent.mkdir(parents=True, exist_ok=True)
    icon.parent.mkdir(parents=True, exist_ok=True)

    icon_png = make_manager_icon(CACHE / "manager-icon.png")

    plist = {
        "CFBundleExecutable": "DockGroupManager",
        "CFBundleIdentifier": "local.dockgroup.manager",
        "CFBundleName": "DockGroup",
        "CFBundleDisplayName": "DockGroup 设置",
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "12.0",
        "NSHighResolutionCapable": True,
        # 没有它，SwiftUI 的 @main App 在 bundle 里不会建出 NSApplication，
        # 表现是「进程起来了但没窗口」。
        "NSPrincipalClass": "NSApplication",
        # DockGroupScript 必须写绝对路径：GUI 进程的 PATH 只有 /usr/bin:/bin，
        # 里面也没有 dg 这个短命令，只能靠 Info.plist 把引擎位置告诉它。
        "DockGroupScript": engine_command(),
    }

    # 图标进摘要：只改画图逻辑不重打包的话，Dock 里还是旧图标。
    digest = hashlib.sha256(
        plistlib.dumps(plist) + binary.read_bytes()
        + icon_png.read_bytes()).hexdigest()
    stamp = CACHE / "manager.bundle-stamp"
    if (force or not exe.exists() or not stamp.exists()
            or stamp.read_text().strip() != digest):
        shutil.copyfile(binary, exe)
        os.chmod(exe, 0o755)
        png_to_icns(icon_png, icon)
        with info.open("wb") as f:
            plistlib.dump(plist, f)
        sh(["codesign", "--force", "--sign", "-", str(app)])
        stamp.write_text(digest)
        if Path(LSREGISTER).exists():
            sh([LSREGISTER, "-f", str(app)])
        for d_ in (app, app / "Contents", app / "Contents/Resources", icon, exe):
            try:
                os.utime(d_, None)
            except OSError:
                pass
    if strip_quarantine(app):
        print(f"  已清除「{app.name}」继承来的隔离属性"
              "（否则首次打开会被 Gatekeeper 拦）")
    return app


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


def _folder_entries(folder: Path):
    """分组文件夹里除「图标载体」外的所有条目。"""
    if not folder.is_dir():
        return []
    return [p for p in folder.iterdir()
            if p.name != ICON_ENTRY and not p.name.startswith(".")]


def collect_apps(g, folder: Path, seed=True):
    """文件夹优先；仅在**文件夹为空**时从配置播种一次，之后文件夹即唯一事实来源。

    为什么不是「缺哪个就补哪个」：那样用户手动删掉的别名（或在 Finder 里删的），
    会在下次 rebuild 时被配置里的旧列表重新播种回来 —— 表现为「删了又自己出现」。
    这与「文件夹是唯一事实来源」的承诺直接冲突。
    """
    if seed:
        folder.mkdir(parents=True, exist_ok=True)
        if not _folder_entries(folder):
            todo = [Path(a).expanduser() for a in g.get("apps", [])]
            if todo:
                jxa("mkalias", folder, *todo)
    apps = read_folder_apps(folder)
    if apps:
        return apps
    return [(Path(a).expanduser().stem, Path(a).expanduser(), False)
            for a in g.get("apps", []) if Path(a).expanduser().exists()]


def build_group(g, icons_only=False, style=DEFAULT_STYLE, seed=None):
    """返回 (folder, mosaic_png, 有效清单, 异常清单)。

    seed 控制「成员从哪来」：
      None（默认）→ 按 not icons_only 决定，兼容原有行为
      True        → 允许从配置播种（只在文件夹为空时真的播）
      False       → **只刷新，绝不改变成员** —— refresh_groups 走这条

    为什么必须区分：`dg del` 删掉别名后会触发刷新，如果刷新时允许播种，
    而文件夹恰好只剩图标载体（被判定为「空」），配置里的旧列表就会把成员
    重新补回来 —— 表现出来就是「删掉的 App 自己又回来了」。
    """
    name = g["name"]
    folder = BASE / name
    if seed is None:
        seed = not icons_only
    apps = collect_apps(g, folder, seed=seed)
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


def dock_plist_override():
    """对照测试用的 Dock 替身路径；没设 `DOCKGROUP_DOCK_PLIST` 时返回 None。

    设了之后：读写 Dock 配置改成读写那个文件，并且**跳过一切会打扰系统的动作**
    （defaults import / 备份 / killall Dock & Finder / 杀启动器）。

    为什么需要它：dock_sync 是整个工具里唯一会改用户 Dock 的地方，恰恰最该被测到；
    可真跑一遍的代价是「两套实现先后把用户的 Dock 真改掉两次」，而且 killall Dock
    从 WorkBuddy 沙箱里跑会把当前命令连带打死（exit 137、零输出）—— 根本拿不到结果。
    Swift 版有同款开关，两边行为必须一致，否则对照测试比的不是同一件事。
    """
    p = os.environ.get("DOCKGROUP_DOCK_PLIST")
    return Path(p) if p else None


def dock_read(refresh: bool = False) -> dict:
    """读 Dock 配置。同一次命令里反复读没意义，缓存住；
    dock_write 会同步更新缓存，不会读到脏数据。"""
    global _dock_cache
    if _dock_cache is None or refresh:
        override = dock_plist_override()
        if override is not None:
            _dock_cache = plistlib.loads(override.read_bytes()) if override.exists() else {}
        else:
            _dock_cache = plistlib.loads(sh(["defaults", "export", DOCK_DOMAIN, "-"]).stdout.encode())
    return _dock_cache


def dock_write(pl: dict):
    global _dock_cache
    # DOCKGROUP_SKIP_DOCK=1：整体跳过（不备份、不导入、不 killall）——
    # CI / 脚本化场景「只生成产物、绝不打扰 Dock」的总开关。与
    # DOCKGROUP_DOCK_PLIST 的区别：那个是重定向到替身文件，这个是什么都不做。
    # Swift 版 dockWrite 有同款开关，两边行为必须一致。
    if os.environ.get("DOCKGROUP_SKIP_DOCK") == "1":
        print("已跳过 Dock 写入（DOCKGROUP_SKIP_DOCK=1）")
        return
    data = plistlib.dumps(pl)
    if dock_plist_override() is not None:
        dock_plist_override().write_bytes(data)
        _dock_cache = pl
        return
    BACKUP.mkdir(parents=True, exist_ok=True)
    (BACKUP / f"com.apple.dock-{datetime.now():%Y%m%d-%H%M%S}.plist").write_bytes(data)
    subprocess.run(["defaults", "import", DOCK_DOMAIN, "-"], input=data, check=True)
    _dock_cache = pl
    sh(["killall", "Dock"])
    sh(["killall", "Finder"])


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


def _mdfind_app(needle: str):
    """用 Spotlight 按「显示名」找 App —— 这是匹配中文名的唯一可靠路子。

    实测 `NSWorkspace.fullPathForApplication`（下面 resolve_app 用的 findapp）
    **只认英文名**：「System Settings」能命中，「系统设置」返回空。
    中文用户输入中文名是常态，所以必须补这条。
    """
    safe = needle.replace("'", "").replace('"', "").strip()
    if not safe:
        return None
    dirs = []
    for d in APP_DIRS + (str(HOME / "Applications"),):
        dirs += ["-onlyin", d]
    # 先精确、再包含。Spotlight 未建索引时 mdfind 会返回非 0，直接当没找到。
    for q in (f"kMDItemDisplayName == '{safe}'",
              f"kMDItemDisplayName == '*{safe}*'"):
        r = sh(["mdfind"] + dirs + [q])
        if r.returncode != 0:
            continue
        for line in r.stdout.splitlines():
            p = Path(line)
            if p.suffix == ".app" and p.exists():
                return p
    return None


def resolve_app(spec: str):
    """把 'Google Chrome' / 'chrome' / 'Safari' / '系统设置' / 完整路径 解析成 App 路径。"""
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

    # ③ Spotlight 按显示名找 —— ② 只认英文名，中文名（「系统设置」）只有这里能命中
    hit = _mdfind_app(stem)
    if hit:
        return hit

    # ④ 最后退化成文件名模糊匹配
    for d in dirs:
        try:
            for e in sorted(Path(d).iterdir()):
                if e.suffix == ".app" and low in e.stem.lower():
                    return e
        except OSError:
            continue
    return None


# ─────────────────────────────────────────────────────────── 交互模式
#
# 为什么需要：日常 add/new 最烦的不是命令本身，而是「得记组名、得拼对 App 名」。
# 不带参数跑 add / new 就进入引导：列分组、列已安装 App，敲数字多选，回车确认。
# 纯 input() 实现，不引入任何新依赖。


class Cancelled(Exception):
    """用户 Ctrl-C 或主动取消。"""


def ask(prompt, default=""):
    """读一行输入。EOF 当默认值，Ctrl-C 抛 Cancelled。"""
    try:
        suffix = f" [{default}]" if default else ""
        return input(f"{prompt}{suffix}> ").strip()
    except EOFError:
        print()
        return default
    except KeyboardInterrupt:
        print()
        raise Cancelled


def confirm(prompt, default=True):
    """yes/no。default=True 时空回车也算确认。"""
    s = ask(prompt, "y" if default else "n").lower()
    return s in ("y", "yes") or (default and s == "")


def parse_selection(s: str, count: int):
    """'1' / '1,3' / '2-4' → 0 基下标集合。非法返回 None。"""
    picks = set()
    for part in s.replace(" ", "").split(","):
        if not part:
            continue
        m = re.match(r"^(\d+)(?:-(\d+))?$", part)
        if not m:
            return None
        a, b = int(m.group(1)), int(m.group(2) or m.group(1))
        if a < 1 or b > count or a > b:
            return None
        picks.update(range(a - 1, b))
    return picks or None


def list_installed_apps():
    """扫描所有应用目录 → [(显示名, 路径)]，按显示名去重、按名排序。"""
    seen, out = set(), []
    for d in list(APP_DIRS) + [str(HOME / "Applications")]:
        try:
            entries = sorted(Path(d).iterdir(), key=lambda e: e.stem.lower())
        except OSError:
            continue
        for e in entries:
            if e.suffix == ".app" and e.is_dir() and e.stem not in seen:
                seen.add(e.stem)
                out.append((e.stem, e))
    return out


def pick_group(cfg, prompt="选择分组"):
    """交互式选一个分组；只有一个时自动选中。取消返回 None。"""
    groups = cfg["groups"]
    if not groups:
        print("还没有任何分组，先建一个：dg new")
        return None
    if len(groups) == 1:
        print(f"\n只有一个分组「{groups[0]['name']}」，直接用它。")
        return groups[0]

    print(f"\n{prompt}：")
    for i, g in enumerate(groups, 1):
        print(f"  {i:3}. {g['name']:<12} {group_app_count(g)} 个 App")
    while True:
        s = ask("输入序号（q=取消）").lower()
        if s in ("q", "quit", "exit"):
            return None
        picks = parse_selection(s, len(groups))
        if picks is None:
            print("  输入无效：敲序号，如 1")
            continue
        return groups[sorted(picks)[0]]


def prompt_group_name(cfg):
    """问一个不重复的分组名。取消返回 None。"""
    while True:
        name = ask("新分组叫什么名字（如 AI / 工作 / 工具）")
        if not name:
            return None
        if find_group(cfg, name):
            print(f"  「{name}」已存在，换一个")
            continue
        return name


PAGE_SIZE = 15


def _require_tty(cmd):
    """交互模式必须有真实终端；管道/脚本调用时给出用法提示，避免 input() 死循环。"""
    if not sys.stdin.isatty():
        sys.exit(f"交互模式需要终端。在脚本里请用带参数的形式：dg {cmd} <组名> \"App\" ...")


def group_app_count(g):
    """分组里有几个 App：文件夹优先，没建文件夹时回退读配置。"""
    apps = read_folder_apps(BASE / g["name"])
    if apps:
        return len(apps)
    return len(g.get("apps", []))


def pick_apps(cfg, group_name=None):
    """交互式多选 App → [Path]。

    group_name 给定时，该组里已有的 App 会被标记并禁止重复选择。
    流程：输关键词过滤 → 翻页/敲序号多选 → q 完成。
    """
    installed = list_installed_apps()
    if not installed:
        print("  扫描不到已安装的 App")
        return []
    exclude = {n for n, _, _ in read_folder_apps(BASE / group_name)} \
        if group_name else set()
    chosen: list[Path] = []

    print(f"\n共 {len(installed)} 个已安装 App。先输关键词缩小范围，再敲序号多选"
          f"（如 1 或 1,3 或 2-4）。")
    while True:
        kw = ask("关键词过滤（回车=全部，q=完成选择）")
        if kw.lower() == "q":
            return chosen
        cands = [(n, p) for n, p in installed
                 if not kw or kw.lower() in n.lower()]
        if not cands:
            print(f"  没有匹配「{kw}」的 App，换个关键词")
            continue

        page = 0
        while True:
            lo = page * PAGE_SIZE
            chunk = cands[lo:lo + PAGE_SIZE]
            for i, (n, p) in enumerate(chunk, lo + 1):
                tag = ""
                if p in chosen:
                    tag = "✓已选"
                elif n in exclude:
                    tag = "·已在该组"
                print(f"  {i:3}. {n}  {tag}")
            total = len(cands)
            hi = min(lo + PAGE_SIZE, total)
            nav = "，n=下一页" if hi < total else ""
            sel = ask(f"选择（{lo + 1}-{hi}/{total}{nav}，k=重新过滤，q=完成）")
            low = sel.lower()
            if low == "q":
                return chosen
            if not sel:
                if chosen:
                    return chosen
                print("  还没选任何 App。输序号选择，或敲 q 取消。")
                continue
            if low == "k":
                break       # 回到关键词输入
            if low == "n" and hi < total:
                page += 1
                continue
            if low == "p" and page > 0:
                page -= 1
                continue

            picks = parse_selection(sel, total)
            if picks is None:
                print("  输入无效：如 1 或 1,3 或 2-4")
                continue
            for i in sorted(picks):
                n, p = cands[i]
                if n in exclude:
                    print(f"  · 「{n}」已在该组，跳过")
                elif p not in chosen:
                    chosen.append(p)
                    print(f"  ✓ 已选 {n}（共 {len(chosen)} 个）")


def _add_apps(cfg, g, paths):
    """把已解析好的 App 路径加进分组：建别名 → 同步配置 → 刷新图标 → 重启 Dock。

    cmd_add 与交互模式共用这条，保证两条路的行为完全一致。
    返回实际新增的个数。
    """
    gname = g["name"]
    folder = BASE / gname
    folder.mkdir(parents=True, exist_ok=True)

    todo, dup = [], []
    for p in paths:
        if (folder / p.stem).exists():
            dup.append(p.stem)
        elif p not in todo:
            todo.append(p)
    if dup:
        print(f"  · 已在分组里，跳过：{'、'.join(dup)}")
    if not todo:
        # 没有任何新增就直接返回，不做刷新、不重启 Dock。
        # 拖放场景下系统可能把同一个 kAEOpenDocuments 送两次（实测隔 7 秒又来一次），
        # 第二次必须是廉价空操作，否则会白白重启一次 Dock。
        return 0

    jxa("mkalias", folder, *todo)
    for p in todo:
        print(f"  + {p.stem}")

    # 配置里的 apps 列表同步，保证 groups.json 与文件夹一致
    apps = g.setdefault("apps", [])
    known = {str(Path(a).expanduser()) for a in apps}
    for p in todo:
        if str(p) not in known:
            apps.append(str(p))
    save_config(cfg)

    refresh_groups(cfg, {gname}, quiet=True)
    return len(todo)


def interactive_add(cfg):
    """dg add（不带参数）→ 选分组 → 多选 App → 确认 → 自动刷新。"""
    _require_tty("add")
    try:
        if not cfg["groups"]:
            print("还没有分组。先建一个：dg new")
            return
        g = pick_group(cfg, "把 App 加到哪个分组")
        if g is None:
            return
        paths = pick_apps(cfg, g["name"])
        if not paths:
            print("没有选择任何 App。")
            return

        print(f"\n将把以下 App 加进「{g['name']}」：")
        for p in paths:
            print(f"  · {p.stem}")
        if not confirm("确认？"):
            print("已取消")
            return

        added = _add_apps(cfg, g, paths)
        total = len(read_folder_apps(BASE / g["name"]))
        if added:
            print(f"\n「{g['name']}」现在有 {total} 个 App，图标已刷新。")
        else:
            print(f"\n没有新增 App（「{g['name']}」已有 {total} 个）。")
        if not dock_has(g["name"]):
            if confirm(f"「{g['name']}」还没在 Dock 里，现在写进去？"):
                print()
                cmd_apply(cfg, [g["name"]])
    except Cancelled:
        print("已取消")


def interactive_new(cfg):
    """dg new（不带参数）→ 输组名 → 多选 App → 确认 → 问是否直接写进 Dock。"""
    _require_tty("new")
    try:
        name = prompt_group_name(cfg)
        if not name:
            return
        paths = pick_apps(cfg, None)
        if not paths:
            print("没有选择任何 App，分组未创建。")
            return

        print(f"\n将创建分组「{name}」，包含 {len(paths)} 个 App：")
        for p in paths:
            print(f"  · {p.stem}")
        if not confirm("确认创建？"):
            print("已取消")
            return

        g = {"name": name, "enabled": True, "placement": "left",
             "apps": [str(p) for p in paths]}
        cfg.setdefault("groups", []).append(g)
        save_config(cfg)
        print(f"\n已添加分组「{name}」")

        if confirm("直接写进 Dock（自动折叠原图标）？"):
            print()
            cmd_apply(cfg, [name])
        else:
            print(f"\n稍后写进 Dock：dg apply {name}")
            print(f"先看图标长啥样：dg preview {name}")
    except Cancelled:
        print("已取消")


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
        # Pillow 和 CLT 是两条独立的路，缺哪个给哪个的命令。
        # 以前不分情况一律提示 xcode-select —— 只缺 Pillow 的人照着装完 CLT
        # 回来还是报错，白折腾一轮。
        missing = {tool for tool, _, good in checks if not good}
        if "Pillow" in missing:
            print("\n  Pillow 不在 macOS 自带依赖里，需要单独装：")
            print("    /usr/bin/python3 -m pip install --user Pillow")
            print("  必须装给 /usr/bin/python3（本工具固定用它，别的解释器读不到）。")
        if missing & {"swiftc", "codesign", "iconutil", "sips"}:
            # 只有 swiftc 来自 CLT，别把 codesign / iconutil / sips 也算进去 ——
            # 那是 macOS 自带的（xcrun -f 解析回 /usr/bin，CLT 的 bin 里没有它们）。
            # 真缺了说明系统环境有问题，装 CLT 也救不回来，所以分开说。
            if "swiftc" in missing:
                print("\n  swiftc 随 Xcode Command Line Tools 提供：")
                print("    xcode-select --install")
                print("  只想用右侧文件夹模式的话，缺 swiftc 也能跑（placement 设成 right）。")
            sysmiss = missing & {"codesign", "iconutil", "sips"}
            if sysmiss:
                print("\n  这几个是 macOS 自带的，正常不该缺："
                      + "、".join(sorted(sysmiss)))
                print("  缺了说明系统环境异常（检查 /usr/bin 是否被改动过），装 CLT 解决不了。")

    # ── 分发与签名 ──
    # 这一节存在的理由：签名身份和隔离属性都属于「本机自测一路绿灯、发出去才炸」
    # 的事。用户来报「打不开」，先看这里就能分清是哪一种。
    print()
    print("  分发与签名：")

    ident = sh(["security", "find-identity", "-v", "-p", "codesigning"]).stdout or ""
    n_id = len(re.findall(r"^\s+\d+\)", ident, re.M))
    if n_id:
        print(f"    ✅ 签名身份 : {n_id} 个可用（能签 Developer ID，发给别人不会被拦）")
    else:
        print("    ⚠️ 签名身份 : 无 —— 只能用 ad-hoc 签名（codesign -s -）")
        print("              本机自用没问题。把 .app 发给别人，对方会被 Gatekeeper")
        print("              拦下，需要右键→打开，或清掉隔离属性。见 README「分发与签名」。")

    built = sorted(APPS.glob("*.app"))
    if not built:
        print("    ·  产物     : 还没生成过 App")
    else:
        dirty = [a.name for a in built if has_quarantine(a)]
        if dirty:
            print(f"    ⚠️ 隔离属性 : {'、'.join(dirty)} 带 com.apple.quarantine")
            print("              首次打开会被拦。跑 dg rebuild / dg gui 会自动清掉。")
        else:
            print(f"    ✅ 隔离属性 : {len(built)} 个 App 都干净")

        # 产物里的路径是否还有效。
        # .app 的 Info.plist 里存着两项**绝对路径**：DockGroupScript（引擎脚本）
        # 和 DockGroupFolder（分组文件夹）。仓库被移动/改名之后这些路径就失效，
        # 而失效的表现是「拖 App 到 Dock 图标上没反应」—— 启动器只把原因写进
        # .cache/<组>.launch.log，界面上毫无提示（issue #1 里用户建议改用相对
        # 路径，就是这个痛点）。这里主动查出来，省得靠猜。
        stale = []
        for a in built:
            try:
                with (a / "Contents/Info.plist").open("rb") as f:
                    pl = plistlib.load(f)
            except Exception as e:
                stale.append(f"{a.stem}：读不到 Info.plist（{e.__class__.__name__}）")
                continue
            miss = [k for k in ("DockGroupScript", "DockGroupFolder")
                    if pl.get(k) and not Path(pl[k]).exists()]
            if miss:
                stale.append(f"{a.stem}：{'、'.join(miss)} 指向的路径已不存在")
        if stale:
            print(f"    ⚠️ 产物路径 : {len(stale)} 个 App 的依赖路径失效")
            for s in stale:
                print(f"                  {s}")
            print("              表现是「拖 App 到 Dock 图标上没反应」。"
                  "跑 dg rebuild 重建即可。")
        else:
            print(f"    ✅ 产物路径 : {len(built)} 个 App 的依赖路径都在")


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
    do_apply = "--apply" in args
    if not [a for a in args if not a.startswith("--")]:
        return interactive_new(cfg)
    args = [a for a in args if not a.startswith("--")]
    if len(args) < 2:
        sys.exit('用法：new <组名> "App 名或路径" ["更多 App"...]\n'
                 '或直接敲 dg new 进入交互模式（输组名、敲数字选 App）\n'
                 '一步到位：dg new --apply <组名> "App"...  建完直接写进 Dock')
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
        "name": gname, "enabled": True, "placement": "left",
        "apps": [str(p) for p in paths],
    })
    save_config(cfg)
    print(f"已添加分组「{gname}」（{len(paths)} 个 App）：")
    for p in paths:
        print(f"  · {p}")
    if do_apply:
        print()
        cmd_apply(cfg, [gname])
    else:
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
            dest, ok, missing = build_launcher_app(g, style=style,
                                                   material=group_material(cfg, g),
                                                   layout=group_layout(cfg, g))
        print(f"  ✓ {g['name']} → {dest}（{len(ok)} 个 App）")
        if missing:
            print(f"       ⚠ 跳过 {len(missing)} 个不存在的 App")
    dock_sync(cfg, only=None, prune=not keep)
    after = len(dock_read().get("persistent-apps", []))
    print(f"\nDock 左侧 App 图标：{before} → {after}")
    if kill_launchers():
        print("  已结束正在运行的启动器 —— 下次点开面板才会用上新布局")
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
    touched = refresh_groups(cfg, quiet=quiet)
    if not quiet:
        print(f"已刷新：{', '.join(touched) if touched else '无'}（Dock 已重启）")


def cmd_style(cfg, args):
    """换面板底色（毛玻璃材质）。改完立刻重建图标并重启 Dock。

    不带参数 = 看当前用了什么 + 列出所有可选材质。
    """
    rest = [a for a in args if not a.startswith("--")]
    all_ = "--all" in args
    if not rest:
        print(f"默认材质：{cfg.get('material', DEFAULT_MATERIAL)}")
        for g in cfg["groups"]:
            own = g.get("material")
            print(f"  {g['name']:<12} {own or '（跟随默认）'}")
        print("\n可选材质：")
        for k, desc in MATERIALS.items():
            print(f"  {k:<18} {desc}")
        print("\n用法：")
        print("  dg style 组名 hud       只改一个分组")
        print("  dg style --all hud      全部改成 hud")
        print("  dg style 组名 default   该分组退回全局默认")
        return

    if all_:
        mat = rest[0]
    elif len(rest) >= 2:
        mat = rest[1]
    else:
        sys.exit("用法：dg style <组名> <材质>   或   dg style --all <材质>\n"
                 "跑 `dg style` 看不带参数的用法和材质清单")

    if mat != "default" and mat not in MATERIALS:
        sys.exit(f"没有「{mat}」这个材质。可选：\n  "
                 + "\n  ".join(MATERIALS))

    if all_:
        if mat == "default":
            cfg.pop("material", None)
        else:
            cfg["material"] = mat
        for g in cfg["groups"]:
            g.pop("material", None)
        save_config(cfg)
        names = [g["name"] for g in cfg["groups"]]
        print(f"全部 {len(names)} 个分组 → {mat}")
    else:
        g = find_group(cfg, rest[0])
        if not g:
            sys.exit(f"没有分组「{rest[0]}」")
        if mat == "default":
            g.pop("material", None)
        else:
            g["material"] = mat
        save_config(cfg)
        names = [g["name"]]
        print(f"「{g['name']}」→ {mat}")

    # 只有真的建过文件夹/启动器的分组才会被 refresh_groups 碰到
    touched = refresh_groups(cfg, set(names), quiet=True)
    print(f"已更新：{', '.join(touched) if touched else '无'}（Dock 已重启）")
    if not touched:
        print("提示：这些分组还没有生成图标，跑 `dg apply` 才会写进 Dock")


def group_material(cfg, g):
    """取某个分组该用的毛玻璃材质。

    分组自己写了 material 就用自己的，没写才退回顶层默认 —— 这样可以全局定基调、
    个别分组单独换风格（做风格对比时也靠它）。
    以前这里只看顶层 cfg["material"]，分组里写 material 是被静默忽略的。
    """
    return g.get("material") or cfg.get("material", DEFAULT_MATERIAL)


def group_layout(cfg, g):
    """取某个分组该用的网格布局模式。

    和 group_material() 同一套「分组覆盖全局」的规则：分组自己写了 layout 就用
    分组的，没写才退回顶层默认。这样既能全局定基调（dg layout --all row 一键回到
    旧的长条样式），也能给个别分组单独开网格、其余保持长条。
    """
    return str(g.get("layout") or cfg.get("layout", DEFAULT_LAYOUT))


def group_app_count(g):
    """数分组文件夹里的有效条目数。

    过滤规则和启动器 main.swift 的 readEntries() 对齐：跳过 .DS_Store 之类的
    隐藏文件，以及带 \\r 的自定义图标文件（Icon\\r）——它不是 App，不占格子。
    """
    folder = BASE / g["name"]
    if not folder.is_dir():
        return None
    return sum(1 for x in folder.iterdir()
               if not x.name.startswith(".") and "\r" not in x.name)


def cmd_layout(cfg, args):
    """换弹出面板的网格布局（长条 / 自适应网格 / 和 Dock 条等高）。改完重建图标并重启 Dock。

    不带参数 = 看当前用了什么 + 每个分组会排成几宫格。
    """
    rest = [a for a in args if not a.startswith("--")]
    all_ = "--all" in args
    if not rest:
        print(f"默认布局：{cfg.get('layout', DEFAULT_LAYOUT)}")
        for g in cfg["groups"]:
            own = g.get("layout") or "（跟随默认）"
            n = group_app_count(g)
            if n is None:
                print(f"  {g['name']:<12} {own:<14} 文件夹不存在")
                continue
            cols, rows = layout_grid(group_layout(cfg, g), n)
            pw, ph = panel_size(group_layout(cfg, g), n)
            print(f"  {g['name']:<12} {own:<14} {n:>2} 个 App → {cols}×{rows}  {pw}×{ph}")
        print("\n可选布局：")
        for k, desc in LAYOUTS.items():
            print(f"  {k:<10} {desc}")
        print("\n用法：")
        print("  dg layout 组名 row        只让这个分组保持原来的长条样式")
        print("  dg layout 组名 dock       改成和 Dock 条等高（图标撑满、不显示名字）")
        print("  dg layout 组名 dock-name  和 Dock 条等高 + 保留名字（比 Dock 高 8pt）")
        print("  dg layout 组名 dock-grid  和 Dock 条两倍等高 · 无字网格（2×2 = 144×144）")
        print("  dg layout --all auto      全部改成自适应网格")
        print("  dg layout 组名 default    该分组退回全局默认")
        return

    if all_:
        mode = rest[0]
    elif len(rest) >= 2:
        mode = rest[1]
    else:
        sys.exit("用法：dg layout <组名> <模式>   或   dg layout --all <模式>\n"
                 "跑 `dg layout` 看不带参数的用法和布局清单")

    if mode != "default" and mode not in LAYOUTS:
        sys.exit(f"没有「{mode}」这个布局。可选：\n  " + "\n  ".join(LAYOUTS))

    if all_:
        if mode == "default":
            cfg.pop("layout", None)
        else:
            cfg["layout"] = mode
        for g in cfg["groups"]:
            g.pop("layout", None)
        save_config(cfg)
        names = [g["name"] for g in cfg["groups"]]
        print(f"全部 {len(names)} 个分组 → {mode}")
    else:
        g = find_group(cfg, rest[0])
        if not g:
            sys.exit(f"没有分组「{rest[0]}」")
        if mode == "default":
            g.pop("layout", None)
        else:
            g["layout"] = mode
        save_config(cfg)
        names = [g["name"]]
        print(f"「{g['name']}」→ {mode}")

    touched = refresh_groups(cfg, set(names), quiet=True)
    print(f"已更新：{', '.join(touched) if touched else '无'}（Dock 已重启）")
    if not touched:
        print("提示：这些分组还没有生成图标，跑 `dg apply` 才会写进 Dock")


def refresh_groups(cfg, names=None, quiet=False):
    """重建指定分组的图标与启动器，然后重启 Dock。names=None = 全部。

    add / del / rebuild 都走这里，保证「改完即生效」。
    """
    style = cfg.get("style", DEFAULT_STYLE)
    touched, skipped = [], []
    for g in cfg["groups"]:
        if names and g["name"] not in names:
            continue
        if not (BASE / g["name"]).is_dir():
            continue
        try:
            # seed=False：刷新只改图标，绝不改变成员 —— 否则刚删掉的会被配置播种回来
            if g.get("placement", "left") == "right":
                build_group(g, style=style, seed=False)
            else:
                build_launcher_app(g, style=style, material=group_material(cfg, g),
                                   layout=group_layout(cfg, g), seed=False)
            touched.append(g["name"])
        except SystemExit as e:
            skipped.append(str(e))
    if touched:
        CACHE.mkdir(parents=True, exist_ok=True)
        (CACHE / ".last-build").write_text(str(time.time()))
        # 先杀启动器再重启 Dock：顺序反过来的话，重启完 Dock 又有一瞬间可能被点到，
        # 那时旧进程还在，就会用旧布局画一次面板。
        kill_launchers()
        if dock_plist_override() is None:      # 对照测试模式下不碰真实 Dock
            sh(["killall", "Dock"])
            sh(["killall", "Finder"])
    if not quiet:
        for s in skipped:
            print(f"  跳过：{s}")
    return touched


def cmd_add(cfg, args):
    """往已有分组里加 App：建别名 → 同步配置 → 刷新图标 → 重启 Dock。"""
    if not [a for a in args if not a.startswith("--")]:
        return interactive_add(cfg)
    args = [a for a in args if not a.startswith("--")]
    if len(args) < 2:
        sys.exit('用法：add <组名> "App 名或路径" ["更多 App"...]\n'
                 '或直接敲 dg add 进入交互模式（列分组、列 App，敲数字选）')
    gname, specs = args[0], args[1:]
    g = find_group(cfg, gname)
    if not g:
        sys.exit(f"没有分组「{gname}」。新建一个：dg new {gname} "
                 + " ".join(f'"{s}"' for s in specs))

    todo, bad = [], []
    for s in specs:
        p = resolve_app(s)
        if p is None:
            bad.append(s)
        elif p not in todo:
            todo.append(p)
    if bad:
        print(f"  ⚠ 找不到：{'、'.join(bad)}")
    if not todo:
        sys.exit("没有新增任何 App")

    added = _add_apps(cfg, g, todo)
    total = len(read_folder_apps(BASE / gname))
    if added:
        print(f"\n「{gname}」现在有 {total} 个 App，图标已刷新。")
    else:
        print(f"\n没有新增 App（「{gname}」已有 {total} 个）。")
    if not dock_has(gname):
        print(f"它还没在 Dock 里 —— 跑 `dg apply {gname}` 加进去。")


def cmd_del(cfg, args):
    """从分组里移除 App：删别名 → 同步配置 → 刷新图标 → 重启 Dock。

    只删别名文件；条目若是真实 App（目录）则拒绝删除并提示，
    避免误删用户真正的应用程序。
    """
    args = [a for a in args if not a.startswith("--")]
    if len(args) < 2:
        sys.exit('用法：del <组名> "App 名" ["更多 App"...]')
    gname, needles = args[0], args[1:]
    g = find_group(cfg, gname)
    if not g:
        sys.exit(f"没有分组「{gname}」")
    folder = BASE / gname
    if not folder.is_dir():
        sys.exit(f"分组文件夹不存在：{folder}")

    entries = _folder_entries(folder)
    target_of = {n: t for n, t, _ in read_folder_apps(folder)}
    removed, missed, danger = [], [], []
    for n in needles:
        low = n.lower()
        hits = [p for p in entries if low in p.stem.lower()]
        if not hits:
            # 再按 App 名解析一次 —— 覆盖中文输入（「系统设置」→ System Settings 别名）
            want = resolve_app(n)
            if want:
                hits = [p for p in entries if target_of.get(p.name) == want]
        if not hits:
            missed.append(n)
            continue
        for p in hits:
            if p in removed or p in danger:
                continue
            if p.is_dir():
                danger.append(p.name)      # 真实 App（目录），不能删
                continue
            p.unlink()                     # 别名是文件，安全
            removed.append(p)

    if missed:
        print(f"  ⚠ 分组里没有匹配：{'、'.join(missed)}")
    if danger:
        print(f"  ⛔ 这些是真实 App 而非别名，已跳过（要删请手动处理）：{'、'.join(danger)}")
    if not removed:
        sys.exit("没有移除任何 App")

    for p in removed:
        print(f"  - {p.stem}")

    gone = {p.stem.lower() for p in removed}
    g["apps"] = [a for a in g.get("apps", [])
                 if Path(a).expanduser().stem.lower() not in gone]
    save_config(cfg)

    refresh_groups(cfg, {gname}, quiet=True)
    left = len(read_folder_apps(folder))
    print(f"\n「{gname}」现在有 {left} 个 App，图标已刷新。")
    if left == 0:
        print(f"分组已空。加点东西进去（dg open {gname}），或用 dg remove {gname} 摘掉它。")


def cmd_open(cfg, args):
    if not args:
        sys.exit("请指定分组名")
    g = find_group(cfg, args[0])
    if not g:
        sys.exit(f"没有分组「{args[0]}」")
    folder = BASE / g["name"]
    folder.mkdir(parents=True, exist_ok=True)
    if dock_plist_override() is None:      # 对照测试模式下不真开 Finder（Swift 版同款开关）
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
    # 对照测试模式：plist 写进隔离目录的 watch-test.plist（绝不碰真实的
    # ~/Library/LaunchAgents），launchctl 一概不碰 —— 输出走「没权限」分支。
    # 真实模式行为与原先完全一致（agent == AGENT_PLIST）。
    override = dock_plist_override()
    agent = (override.parent / "watch-test.plist") if override is not None else AGENT_PLIST
    agent.parent.mkdir(parents=True, exist_ok=True)
    # 引擎入口复用 engine_command()：dg 二进制能直接 exec；万一退回仓库里的
    # dockgroup.py（.py 不能直接 exec 出可靠解释器），保留 /usr/bin/python3 前缀。
    #
    # ⚠️ 不能写死 python3 + 本脚本：预编译安装（install.command 路径 A）根本
    # 不装 Pillow，而本文件顶部 `from PIL import` 缺包直接 sys.exit ——
    # watch agent 每次被文件夹变动触发都静默崩，自动刷新从未生效。
    # （2026-09-22 对比外部 PR 时发现；Swift 侧 Watch.swift 有同款修复。）
    # DOCKGROUP_HOME 也必须显式带进 agent：launchd 环境里没有用户的 shell
    # 配置，BASE 若是自定义位置，agent 里的 rebuild 会找错配置目录。
    ec = engine_command()
    prog_args = (["/usr/bin/python3", ec] if ec.endswith(".py") else [ec]) \
        + ["rebuild", "--quiet"]
    agent.write_bytes(plistlib.dumps({
        "EnvironmentVariables": {"DOCKGROUP_HOME": str(BASE)},
        "Label": AGENT_LABEL,
        "ProgramArguments": prog_args,
        "WatchPaths": [str(BASE / g["name"]) for g in cfg["groups"]],
        "RunAtLoad": False,
        "ThrottleInterval": 5,
    }))
    domain = f"gui/{uid()}"
    if override is None:
        subprocess.run(f"launchctl bootout {domain} {agent} >/dev/null 2>&1", shell=True)
        r = subprocess.run(f"launchctl bootstrap {domain} {agent}",
                           shell=True, capture_output=True, text=True)
    else:
        r = None
    if r is not None and r.returncode == 0:
        print(f"已写入并启用 {agent}")
        print("自动监听生效：往分组文件夹里加/删 App，图标会自动更新。")
    else:
        print(f"已写入 {agent}")
        print("但当前进程没有 launchd 权限，无法自动加载。请在你自己的「终端」里执行一次：")
        print(f"  launchctl bootstrap {domain} {agent}")
    print("注：之后新增分组文件夹，需要重新跑一次 watch-install 才会被监听。")


def cmd_watch_uninstall(cfg, args):
    override = dock_plist_override()
    agent = (override.parent / "watch-test.plist") if override is not None else AGENT_PLIST
    if override is None:
        subprocess.run(f"launchctl bootout gui/{uid()} {AGENT_PLIST}", shell=True,
                       capture_output=True, text=True)
    agent.unlink(missing_ok=True)
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
    if dock_plist_override() is None:      # 对照测试模式下不真启动（Swift 版同款开关）
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
    if dock_plist_override() is not None:
        # 对照测试：替身文件收下原始字节，不碰真 Dock（Swift 版同款开关）。
        # restore 是唯一故意绕过 dock_write 直灌字节的路径，进哪里都必须可测。
        dock_plist_override().write_bytes(data)
    else:
        subprocess.run(["defaults", "import", DOCK_DOMAIN, "-"], input=data, check=True)
        sh(["killall", "Dock"])
    print(f"已从 {src} 恢复 Dock")


QUICK_HELP = """dg — macOS Dock 分组管理

日常四条（都会自动刷新图标并重启 Dock）：
  dg add  组名 App...   往分组里加 App（App 名支持模糊匹配）
  dg del  组名 App...   从分组里删 App
  dg new  组名 App...   新建分组
  dg apply [组名...]    写进 Dock（不填 = 全部启用中的分组）

不想敲名字时（交互引导，敲数字选）：
  dg add               列分组 → 过滤 App → 多选 → 自动刷新
  dg new               输组名 → 多选 App → 建完问你要不要直接写进 Dock
  dg new --apply 组名 App..   新建并一步写进 Dock

其它：
  dg gui                打开图形界面（分组管理窗口，改完即时预览）
  dg list               分组与 Dock 状态
  dg open 组名          在 Finder 里打开分组文件夹
  dg logs 组名          查看运行日志
  dg remove 组名        从 Dock 移除（保留文件夹）
  dg clean  组名        从 Dock 移除并删掉文件夹
  dg rebuild            全部重新生成图标
  dg style [组名|--all] [材质]   换面板底色（不带参数 = 看现状 + 材质清单）
  dg doctor             依赖体检
  dg restore            出错了回滚 Dock
  dg --help             完整说明
"""


def cmd_gui(cfg, args):
    """打开图形界面：分组管理窗口。

    第一次跑要编译打包（十来秒），之后走缓存秒开。窗口里改「外观」是即时出图的，
    但和命令行一样，得点「应用到 Dock」才真正写进 Dock —— 这个分界是故意的：
    外观可以随便试，试错成本为零。
    """
    app = build_manager_app(force="--rebuild" in args)
    print(f"管理窗口：{app}")
    no_open = "--no-open" in args
    if no_open:
        # 只构建不开窗：install.command 用它预装到「应用程序」
        print("已构建，未启动（安装完成后再打开也一样）。")
    else:
        if dock_plist_override() is None:   # 对照测试模式下不真开（Swift 版同款开关）
            sh(["open", str(app)])
        print("已打开。加 App、换外观、应用/回滚都能在里面点。")
    print(f"（改不了界面本身的话，源码在 {SCRIPT_DIR / MANAGER_SRC}）")


def print_quick_help():
    print(QUICK_HELP)
    groups = load_config().get("groups", [])
    if not groups:
        print('当前还没有分组。建一个试试：dg new 工作 "Safari" "备忘录"')
        return
    print("当前分组：")
    for g in groups:
        n = len(read_folder_apps(BASE / g["name"]))
        where = "已在 Dock" if dock_has(g["name"]) else "不在 Dock"
        print(f"  {g['name']:<12} {n} 个 App   {where}")


def main():
    argv = sys.argv[1:]
    if not argv:
        print_quick_help()
        return
    if argv[0] in ("-v", "--version", "version"):
        print(f"dockgroup {__version__}")
        return
    if argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    table = {
        "doctor": cmd_doctor, "init": cmd_init, "new": cmd_new,
        "add": cmd_add, "del": cmd_del, "rm": cmd_del,
        "list": cmd_list, "preview": cmd_preview, "apply": cmd_apply,
        "rebuild": cmd_rebuild, "style": cmd_style, "layout": cmd_layout,
        "open": cmd_open, "test": cmd_test,
        "logs": cmd_logs, "remove": cmd_remove, "clean": cmd_clean,
        "watch-install": cmd_watch_install,
        "watch-uninstall": cmd_watch_uninstall, "restore": cmd_restore,
        "gui": cmd_gui,
    }
    if cmd not in table:
        sys.exit(f"未知命令：{cmd}（跑 `dg` 看可用命令）")
    table[cmd](load_config(), args)


if __name__ == "__main__":
    main()
