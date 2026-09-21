// swift/Core/PanelGeometry.swift
//
// 材质清单、布局清单，以及面板几何的**预览**算法。
// 对应 Python 的 MATERIALS / LAYOUTS / panel_geom / layout_grid / panel_size /
// group_app_count。
//
// ⚠️ 这里的几何必须和 scripts/launcher/main.swift 的 geometry(for:) 逐条对应 ——
// 真正画面板的是启动器那侧，这边只用来在 `dg layout` 里预览「这个分组会排成几宫格、
// 面板多大」。三份实现（本文件 / dockgroup.py / readme_assets.py）改一边就要改另两边。

import Foundation

// ─────────────────────────────────────────────── 材质（面板底色）

/// 键顺序就是打印顺序（Python 的 dict 保序）。
let MATERIALS: [(String, String)] = [
    ("hud", "深色玻璃（当前默认）。白底 App 图标在浅色底上会和背景糊在一起，用这个最清楚"),
    ("menu", "半透明灰玻璃，最接近 Dock 栏的质感"),
    ("popover", "接近纯白（系统 popover 的底色）"),
    ("toolTip", "深色提示框，比 hud 淡一点"),
    ("sidebar", "侧边栏材质"),
    ("header", "表头材质"),
    ("titlebar", "标题栏材质"),
    ("underWindow", "窗口背景之下"),
    ("contentBackground", "内容背景"),
    ("sheet", "表单材质"),
    ("windowBackground", "窗口背景色"),
    ("appearanceBased", "跟随系统外观（老的 appearanceBased 行为）"),
    ("fullScreenUI", "全屏 UI 材质"),
]

// ─────────────────────────────────────────────── 布局（网格模式）

/// 默认是 row（长条）—— 最早的行为，也是观感上更贴合 Dock 的一条横带。
/// auto（按应用数排四宫格 / 九宫格）是**可选项**，用 `dg layout --all auto` 开。
/// 详细取舍见 dockgroup.py 常量区的长注释，这里不重复。
let LAYOUTS: [(String, String)] = [
    ("row", "长条（当前默认）。能铺一行就铺一行，超过 4 个按 4 列换行"),
    ("auto", "自适应网格。1→1×1，2→2×1，3~4→2×2 四宫格，"
             + "5~6→3×2，7~9→3×3 九宫格，≥10→4 列"),
    ("dock", "和 Dock 条等高（72）。图标 44 = Dock 图标同大，不画名字（悬停出系统提示）；"
             + "4 个 App 是 242×72，弹在 Dock 上像同一条栏的延续"),
    ("dock-name", "和 Dock 条等高，另让 8pt 给名字（80）。图标 42 = Dock 图标真实大小；"
                  + "4 个 App 是 378×80"),
    ("dock-grid", "和 Dock 条两倍等高 · 无字网格。格子与 dock 同源（图标 44、不画名字），"
                  + "两行时面板高 = 条高 ×2；3~4 个 App 是 144×144（同时也是正方形）"),
    ("2", "固定 2 列"),
    ("3", "固定 3 列"),
    ("4", "固定 4 列"),
]

/// 列数上限，必须和启动器 main.swift 的 kMaxCols 一致。
let MAX_COLS = 4

/// 格子尺寸，必须和启动器 main.swift 的 kCellW / kCellH / kCellWGrid 一致。
let CELL_W_ROW = 86
let CELL_H = 100
let CELL_W_GRID = 100
let CELL_PAD = 16
let CELL_GAP = 7

/// Dock 条默认高度与 dock 系的留白。
///
/// 启动器那侧是按「屏幕可用区 - 8」实时算的（本机 = 72）；这边拿不到屏幕尺寸，
/// 只能用同一个默认值做**预览**估算 —— 用户在 Dock 设置里改过图标大小的话，
/// 这里显示的尺寸会和真机略有出入。这是原版就有的已知偏差，照抄。
let DOCK_BAR_DEFAULT = 72
let DOCK_PAD = 14
let DOCK_GAP = 6
let DOCK_NAME_PAD = 8   // dock-name 另算：要让出 8pt 给名字

/// 该布局的 (格子宽, 格子高, 内边距, 间距)。
func panelGeom(_ mode: String) -> (w: Int, h: Int, pad: Int, gap: Int) {
    let m = mode.trimmingCharacters(in: .whitespaces).lowercased()
    if m == "dock" || m == "dock-name" {
        if m == "dock" {
            let icon = DOCK_BAR_DEFAULT - DOCK_PAD * 2      // 44 = Dock 图标同档
            return (icon + 8, icon, DOCK_PAD, DOCK_GAP)
        }
        return (CELL_W_ROW, DOCK_BAR_DEFAULT - DOCK_NAME_PAD * 2 + 8, DOCK_NAME_PAD, DOCK_GAP)
    }
    if m == "dock-grid" {
        // 格子取正方，且让「两行 = 两倍条高」成立：
        //   2*bar = pad*2 + 2*cell + gap  →  cell = bar - pad - gap/2 = 55（bar=72）
        // ⚠️ Python 是 `int(...)` 截断，这里也得截断，不能四舍五入。
        let cell = DOCK_BAR_DEFAULT - DOCK_PAD - DOCK_GAP / 2
        return (cell, cell, DOCK_PAD, DOCK_GAP)
    }
    return (m == "row" ? CELL_W_ROW : CELL_W_GRID, CELL_H, CELL_PAD, CELL_GAP)
}

/// 按布局模式算 (列数, 行数)。
///
/// ⚠️ 必须和启动器 main.swift 的 columns(for:layout:) 逐条对应。
/// 注意 `dock-grid` 走的是**兜底那一支**（和 auto 同一套推导）—— 这是原版行为，
/// 别「顺手」把它接到 dock 系的分支上去。
func layoutGrid(_ mode: String, _ n: Int) -> (cols: Int, rows: Int) {
    let count = max(n, 1)
    let m = mode.trimmingCharacters(in: .whitespaces).lowercased()

    var cols: Int
    if let fixed = Int(m), fixed > 0 {
        cols = min(fixed, count)
    } else if m == "row" || m == "dock" || m == "dock-name" {
        cols = min(MAX_COLS, count)          // dock 系共用长条的单行行为
    } else {                                 // auto，也是未知取值的兜底
        let c: Int
        if count <= 2 { c = count }          // 1→1×1，2→2×1
        else if count <= 4 { c = 2 }         // 四宫格
        else if count <= 9 { c = 3 }         // 3×2 或九宫格
        else { c = MAX_COLS }
        cols = min(min(c, count), MAX_COLS)
    }
    cols = max(cols, 1)
    // Python 是 `-(-n // cols)`：向上取整。用到整除而不是浮点，避免 0.999… 的边界。
    let rows = (count + cols - 1) / cols
    return (cols, rows)
}

/// 按布局模式算面板的 (宽, 高)。
func panelSize(_ mode: String, _ n: Int) -> (w: Int, h: Int) {
    let (cols, rows) = layoutGrid(mode, n)
    let g = panelGeom(mode)
    return (g.pad * 2 + cols * g.w + (cols - 1) * g.gap,
            g.pad * 2 + rows * g.h + (rows - 1) * g.gap)
}

// ─────────────────────────────────────────────── 分组条目数

/// 数分组文件夹里的有效条目数。文件夹不存在返回 nil。
///
/// 过滤规则和启动器 main.swift 的 readEntries() 对齐：跳过 `.DS_Store` 之类的
/// 隐藏文件，以及带 \r 的自定义图标载体（`Icon\r`）—— 它不是 App，不占格子。
func groupAppCount(_ g: JSONObject) -> Int? {
    let folder = BASE.appendingPathComponent(g.name)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
          isDir.boolValue,
          let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    else { return nil }
    return entries.filter { !$0.hasPrefix(".") && !$0.contains("\r") }.count
}
