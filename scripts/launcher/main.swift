// DockGroup Launcher
//
// 一个极小的启动器：作为普通 App 固定在 Dock 左侧 App 区，图标是分组的拼贴图。
// 点击后在 Dock 图标正上方弹出该分组内 App 的图标网格，点其中任意一项直接启动。
//
// 为什么需要它：macOS 的文件夹 Stack 弹窗逻辑和 tile 所在区域绑定 ——
// 文件夹放进左侧 App 区后，点击只会打开 Finder 窗口，不会弹网格。
// 换成真正的 App，点击行为就完全由自己控制，而且 App tile 在左侧是原生支持的。
//
// 分组内容在运行时从 Info.plist 的 DockGroupFolder 指向的文件夹里现读现解析，
// 所以往文件夹里加/删 App 只需 rebuild 图标，不用重编译。

import Cocoa

// ─── 布局常量 ──────────────────────────────────────────────
//
// 尺寸对着「Dock 图标 64pt + 下方一行标签」来定。
// 试过三种版式（都出图比对过）：
//   ① 每格加深灰圆角底块 + 描边 → 像表格，视觉很重，淘汰
//   ② 每格加白色磨砂底块        → 像一排白瓷片，和浅色玻璃糊在一起，淘汰
//   ③ 不加底块，只有图标 + 标签  → 和原生 Dock Stack 一致，最干净 ✅
// 间距也别收太紧：格子 80pt 时「DSH Desktop」会被截成「DSH Deskt...」，
// 86pt 是刚好装下常见长名字的宽度，再窄标签就要截断了。
//
// 下面这组是 row / auto / 数字 三种模式的尺寸。想「和 Dock 条一样高」的是
// dock / dock-name 两种模式 —— 它们的尺寸不写死在这儿，而是按屏幕可用区反推
// Dock 条的实际高度（见 dockBarHeight()），否则用户一改 Dock 大小就对不齐了。
let kIcon: CGFloat = 58
let kCellH: CGFloat = 100          // 格子高度。两种布局共用
let kCellW: CGFloat = 86           // 长条模式的格子宽度：横向排开，窄一点更紧凑
/// 网格模式的格子宽度。**必须等于 kCellH** —— 格子方了，n×n 的面板才是正方形。
/// 之前网格也沿用 86 宽，于是 2×2 的面板是 211×239 的竖长方形，和手机上的文件夹
/// 观感差得远（用户原话「四宫格都不像正方形」）。
///
/// 格子高度压不下去：图标和标签都是从格子底部锚定的（图标 y = H-12-58，
/// 标签 y = 10 高 15），所以 H 最小是 25+58+12 = 95。要正方形只能加宽到 100。
let kCellWGrid: CGFloat = 100
let kPad: CGFloat = 16
let kGap: CGFloat = 7
let kTileRadius: CGFloat = 15      // 悬停高亮的圆角
let kPanelRadius: CGFloat = 25     // 面板圆角（必须设在 theme frame 上，见 roundWindow）
let kPanelTint: CGFloat = 0.5      // 匀色底的不透明度，见 ShineView 注释

/// 列数上限，只作为兜底：具体列数由 columns(for:layout:) 按应用数推导。
/// 早期这里是 `let cols = min(kMaxCols, n)` —— n ≤ 4 时 cols 恒等于 n、
/// 行数恒为 1，所以面板永远是单行长条（换行逻辑写了但永远触发不到）。
let kMaxCols = 4

/// 这几个材质本身是深色的。面板挂上深色外观后，子视图的动态色才会翻白。
let kDarkMaterials: Set<String> = ["hud", "toolTip"]

// 面板收起后多久自动退出进程。
// 为什么不做成「用完立刻退出」：那时第二个实例还没退干净，你再点 Dock 图标，
// Dock 会尝试再启动一个实例，被 LaunchServices 拒绝并弹
// 「应用程序"X"已不能再打开」。常驻一小段时间就能让第二次点击走 reopen 路径。
// 可用 DOCKGROUP_IDLE_SECONDS 覆盖（测试用）。
let kIdleSeconds: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["DOCKGROUP_IDLE_SECONDS"],
       let v = Double(s) {
        return v
    }
    return 600
}()

struct Entry {
    let title: String
    let path: String
}

/// 一个布局算出来之后的实际几何。
struct PanelGeometry {
    let cellW: CGFloat
    let cellH: CGFloat
    let pad: CGFloat
    let gap: CGFloat
    /// 图标边长。dock 系模式会把它压到和 Dock 图标同一档，所以不再是全局常量。
    let icon: CGFloat
    /// 是否在图标下方画名字。dock 模式不画 —— 高度全留给图标，名字走悬停原生提示
    /// （system Dock 也是这么做的：名字只出现在指针停上去的时候）。
    let showLabel: Bool
    /// 图标底边距格子底边的高度。有名字时要让出标签的位置，所以两种模式取值不同。
    let iconInset: CGFloat
    /// 标签盒的 y 坐标。showLabel = false 时无意义。
    let labelY: CGFloat

    func panelSize(cols: Int, rows: Int) -> NSSize {
        NSSize(width: pad * 2 + CGFloat(cols) * cellW + CGFloat(cols - 1) * gap,
               height: pad * 2 + CGFloat(rows) * cellH + CGFloat(rows - 1) * gap)
    }
}

/// Dock 条实际有多高（pt）。dock / dock-name 两种模式的高度基准。
///
/// 怎么量出来的（2026-09-20 实测）：屏幕可用区已经排掉了 Dock 占用的空间，
/// 但它比 Dock 条本身多一圈留白 —— 本机（Dock 图标 64、底部 Dock、1408×881）
/// `visibleFrame.minY - frame.minY = 80`，而 2x 截图的像素测量给出：Dock 条上沿
/// 在 77.5pt、下沿约 5.5pt，也就是**条高 ≈ 72pt**，另外 8pt 是系统留白。
/// 所以按「可用区高度 - 8」估，再夹进 [56, 96]：跟着用户的 Dock 大小走，
/// 又不会被异常值带跑（Dock 隐藏或贴侧边时 reserved ≤ 0，直接用默认值）。
func dockBarHeight() -> CGFloat {
    guard let main = NSScreen.main else { return 72 }
    let reserved = main.visibleFrame.minY - main.frame.minY
    guard reserved > 20 else { return 72 }
    return min(max(reserved - 8, 56), 96)
}

/// 按布局模式给出一整套几何。
///
///   row        长条。86×100 格子，图标 58 + 名字
///   auto       自适应网格。100×100 格子（格子方了 n×n 才是正方形），图标 58 + 名字
///   数字       指定列数，格子同 auto
///   dock       **和 Dock 条等高**：条高 72 → 面板 72。上下各留 14pt，图标 = 44，
///              正好是 Dock 图标自己的大小和留白节奏（实测 Dock 图标 42.5pt、
///              上下留白各约 14.5pt）—— 弹在 Dock 正上方就像同一条栏的延续。
///              不画名字（高度全留给图标，名字走悬停原生提示）。4 个 App = 242×72。
///   dock-name  同上，但让 8pt 给名字（面板 80），图标 42 = Dock 图标的真实大小。
///              名字照常显示，代价是比 Dock 条高一点点。4 个 App = 378×80。
///   dock-grid  **和 Dock 条两倍等高**的无字网格：格子取正方 55（= bar - pad - gap/2），
///              于是两行时面板高正好是条高的两倍 —— 2×2 = 144×144，同时也还是正方形。
///              图标 44 = Dock 图标同档，不画名字。和 auto 的分工：auto 是独立的大格子
///              （100）+ 名字，根本不看 Dock 尺寸；dock-grid 一切都从条高推。
func geometry(for layout: String) -> PanelGeometry {
    let mode = layout.trimmingCharacters(in: .whitespaces).lowercased()

    if mode == "dock" || mode == "dock-name" {
        let bar = dockBarHeight()
        if mode == "dock" {
            // 不画名字：图标拿「条高 - 上下留白」，留白取 14 —— 和 Dock 条自己的一致，
            // 于是面板里的图标和 Dock 里的图标一样大，视觉上直接连成一条。
            let pad: CGFloat = 14, gap: CGFloat = 6
            let icon = bar - pad * 2
            return PanelGeometry(cellW: icon + 8, cellH: icon, pad: pad, gap: gap,
                                 icon: icon, showLabel: false, iconInset: 0, labelY: 0)
        }
        // 有名字：格子里自下而上是「标签(4+13) → 图标 → 4pt 边距」，
        // 图标上限锁在 Dock 图标的 42 —— 再大就顶到标签了，而且比 Dock 里的邻居还大。
        let pad: CGFloat = 8, gap: CGFloat = 6
        let cellH = bar - pad * 2 + 8
        let icon = min(cellH - 4 - 17, 42)
        return PanelGeometry(cellW: kCellW, cellH: cellH, pad: pad, gap: gap,
                             icon: icon, showLabel: true, iconInset: 4, labelY: 4)
    }

    if mode == "dock-grid" {
        // 让「两行 = 两倍条高」成立：2*bar = pad*2 + 2*cell + gap → cell = bar - pad - gap/2。
        // bar = 72 时 cell = 55，图标取格子的 0.8 ≈ 44 —— 正好和 Dock 图标同档。
        // 格子是正方，所以 2×2 = 144×144：既是条高两倍，又天然是正方形。
        let bar = dockBarHeight()
        let pad: CGFloat = 14, gap: CGFloat = 6
        let cell = bar - pad - gap / 2
        return PanelGeometry(cellW: cell, cellH: cell, pad: pad, gap: gap,
                             icon: (cell * 0.8).rounded(), showLabel: false,
                             iconInset: 0, labelY: 0)
    }

    // 长条模式保持原来的 86×100 不变；网格模式换 100×100，于是 2×2 是 239×239、
    // 3×3 是 346×346，都是正方形。
    return PanelGeometry(cellW: mode == "row" ? kCellW : kCellWGrid,
                         cellH: kCellH, pad: kPad, gap: kGap,
                         icon: kIcon, showLabel: true, iconInset: 12, labelY: 10)
}

/// 按「应用数 + 布局模式」推导网格列数。
///
/// 布局模式来自 Info.plist 的 `DockGroupLayout`，由 dockgroup.py 按 groups.json
/// 的 `layout` 字段写入。和 material 一样是「分组覆盖全局」：分组自己写了用分组的，
/// 没写才退回顶层默认值（见 dockgroup.py 的 group_layout()）。
///
///   row   —— **默认**。旧的长条样式：能铺一行就铺一行，放不下才按 kMaxCols 换行
///   dock / dock-name —— 同样单行铺开（只是格子尺寸不同，见 geometry(for:)）
///   dock-grid —— **走网格**（和 auto 同一套列数推导），只是格子小一号且不画名字
///   auto  —— 按应用数选最接近正方形的网格：
///             1 个 → 1×1          2 个 → 2×1
///             3~4 个 → 2×2（四宫格）
///             5~6 个 → 3×2
///             7~9 个 → 3×3（九宫格）
///             ≥10 个 → 按 kMaxCols 换行兜底
///   数字    —— 直接指定列数，如 "3"。想精确控制某个分组时用
///
/// 1~2 个刻意不用 2×2：容器会高 239pt 而只装 1~2 个图标，下半截空着像没加载完。
func columns(for n: Int, layout: String) -> Int {
    let n = max(n, 1)
    let mode = layout.trimmingCharacters(in: .whitespaces).lowercased()

    // 直接指定列数
    if let fixed = Int(mode), fixed > 0 {
        return max(1, min(fixed, n))
    }
    // 旧的长条行为：单行铺开，超上限才换行。dock / dock-name 共用这条 ——
    // 它们要的就是「和 Dock 一样的一条」，换行会让高度翻倍、立刻不像 Dock。
    if mode == "row" || mode == "dock" || mode == "dock-name" {
        return max(1, min(kMaxCols, n))
    }

    let want: Int
    switch n {
    case 1:     want = 1         // 单个格子
    case 2:     want = 2         // 2×1，横着放两个最自然
    case 3...4: want = 2         // 2×2 四宫格
    case 5...6: want = 3         // 3×2
    case 7...9: want = 3         // 3×3 九宫格
    default:    want = kMaxCols  // ≥10 个：按上限换行兜底
    }
    return max(1, min(min(want, n), kMaxCols))
}

/// 把配置里的材质名映射到 AppKit 的效果材质。
/// macOS 没有公开的「Dock 材质」，与 Dock 栏观感最接近的公开选项是 `.menu`
/// （和菜单栏同一套材质，浅色模式下是半透明灰玻璃，深色模式自动变深）。
/// `.popover` 是接近纯白的，放白底 App 图标会糊 —— 这就是「面板太白」的来源。
func material(named name: String) -> NSVisualEffectView.Material {
    switch name {
    case "hud":                return .hudWindow
    case "sidebar":            return .sidebar
    case "header":             return .headerView
    case "popover":            return .popover
    case "titlebar":           return .titlebar
    case "underWindow":        return .underWindowBackground
    case "contentBackground":  return .contentBackground
    case "sheet":              return .sheet
    case "windowBackground":   return .windowBackground
    case "appearanceBased":    return .appearanceBased
    case "fullScreenUI":       return .fullScreenUI
    case "toolTip":            return .toolTip
    default:                   return .menu
    }
}

// ─── 事件日志（无 GUI 权限时唯一的排查手段）──────────────────
var logPath = ""
var eventLogPath = ""

func trace(_ msg: String) {
    guard !eventLogPath.isEmpty else { return }
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    let line = "[\(ts)] \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: eventLogPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        try? fh.close()
    } else {
        try? line.write(toFile: eventLogPath, atomically: true, encoding: .utf8)
    }
}

// ─── 拖放加入分组 ──────────────────────────────────────────
//
// macOS 的 Dock **不允许**「把一个 Dock 图标拖到另一个 Dock 图标上」
// （拖动 Dock 图标时整个拖拽会话被 Dock 接管，只能排序/拖出移除）。
// 但「把 Finder 里的文件拖到 Dock 上的 App 图标」是系统支持的：走
// kAEOpenDocuments 苹果事件，App 收到的就是被拖文件的 URL/路径。
//
// 所以「拖 App 到分组图标上加入分组」是可以做的：启动器截获这个事件，
// 调 Python 脚本走和 `dg add` 完全一样的链路（建别名 → 刷新图标 → 重启 Dock）。
// 拖到展开的网格面板上同理（面板注册了 fileURL 拖放）。
// 来源必须是 Finder 里的 App 文件（如 /Applications 窗口），不能是 Dock 图标本身。

/// 面板边缘的受光高光。
///
/// 面板最上面一层装饰：整块匀色底 + 边缘一圈受光。
///
/// 为什么匀色底是必要的：`blendingMode = .behindWindow` 的毛玻璃会实时采样窗口
/// **背后**的内容。面板横跨在「左边是深色窗口、右边是浅色桌面」这类边界上时，
/// 玻璃就左半边深、右半边浅，看起来像被劈成两半 —— 实测同一块面板内部亮度能从
/// 50 平滑爬到 154。系统自己的 Dock 也这样，但 Dock 背后永远只有壁纸，而我们这个
/// 面板弹在任意窗口之上，背景不可控。压一层半透明匀色底把自适应抹平，
/// 面板在任何背景下都是同一块稳定的「表面」。
///
/// 为什么要单独一层：NSVisualEffectView 的 `draw(_:)` 由系统实现（负责画材质），
/// 覆写它会把毛玻璃一起干掉。所以叠一个透明子视图，在它上面画匀色底和边缘高光。
/// `hitTest` 返回 nil，不参与点击，事件照常落到下面的背景视图上。
final class ShineView: NSView {
    var radius: CGFloat = kPanelRadius
    /// 诊断用：整块面板的深浅判定只记一次，免得每次重绘都刷日志
    private static var tracedOnce = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if !Self.tracedOnce {
            Self.tracedOnce = true
            // 匀色底压黑还是压白全看这个判定：判错了深色面板会被压成一片浅灰，
            // 而 Info.plist 里材质写对了也看不出来 —— 所以必须落日志。
            trace("shine: dark=\(dark) appearance=\(effectiveAppearance.name.rawValue)")
        }
        let r = radius
        let outer = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)

        // ① 匀色底：深色材质压黑、浅色材质压白。两种外观下都是「提高不透明度」
        //    而不是「染色」，所以不会偏离材质本身的色相。
        (dark ? NSColor.black : NSColor.white)
            .withAlphaComponent(kPanelTint).setFill()
        outer.fill()

        // ② 边缘一圈受光：外圆角矩形挖掉内圆角矩形，竖直渐变填 —— 顶部亮、底部微暗。
        //    少了这一圈，整块面板就是一张平的灰板，没有材质感。
        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                 xRadius: r - 0.75, yRadius: r - 0.75)
        outer.append(inner)
        outer.windingRule = .evenOdd
        outer.addClip()
        let colors = dark
            // 深色玻璃上高光要收敛：白色 0.26 会在顶边镶出一条硬亮线，像描了边框。
            ? [NSColor.white.withAlphaComponent(0.16),
               NSColor.white.withAlphaComponent(0.04),
               NSColor.black.withAlphaComponent(0.06)]
            : [NSColor.white.withAlphaComponent(0.80),
               NSColor.white.withAlphaComponent(0.16),
               NSColor.black.withAlphaComponent(0.04)]
        NSGradient(colors: colors)?.draw(in: bounds, angle: -90)
    }
}

/// 接收拖放的面板背景：注册 fileURL 拖放，拖 App 进来时高亮边框。
final class DropVisualEffectView: NSVisualEffectView {
    var onDrop: ((_ urls: [URL]) -> Void)?
    /// 点在面板空白处（没落到图标格子上）时回调 —— 用来关闭面板
    var onEmptyClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// 常态描边色。之前这里硬编码了白色 0.22，浅色模式下等于没有描边，
    /// 面板边缘会糊进背景里 —— 得跟着外观走。
    private var idleBorder: CGColor {
        let dark = effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.10).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onEmptyClick?()
    }

    private func draggedApps(_ sender: NSDraggingInfo) -> [URL] {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "app" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !draggedApps(sender).isEmpty else { return [] }   // 非 App 不接管
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderWidth = 0.5
        layer?.borderColor = idleBorder
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0.5
        layer?.borderColor = idleBorder
        let apps = draggedApps(sender)
        guard !apps.isEmpty else { return false }
        onDrop?(apps)
        return true
    }
}

// ─── 面板 ──────────────────────────────────────────────────
final class LauncherPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        trace("dismiss: Esc")
        onCancel?()
    }
}

// ─── 网格里的一个图标格子 ──────────────────────────────────
//
// 刻意不用 NSButton：NSButton 在「非激活 App 的非激活面板」里可能因为
// 首次点击语义（acceptsFirstMouse）而吞掉 mouseDown。这里自己画 + 自己接
// mouseDown，并显式 acceptsFirstMouse = true，链路上不留不确定因素。
final class ItemView: NSView {
    private let index: Int
    private let title: String
    private let icon: NSImage
    /// 尺寸随布局走（dock 模式的图标比长条模式小），所以整份几何都带进来，
    /// 不读全局常量 —— 否则 dock 模式会按长条模式的 58pt 画。
    private let geom: PanelGeometry
    private let onPick: (Int) -> Void
    private var area: NSTrackingArea?
    /// 悬停状态。标签颜色跟着它走（默认灰、悬停转正文色），所以要触发重绘。
    private var hovered = false

    init(index: Int, title: String, icon: NSImage, geom: PanelGeometry, frame: NSRect,
         onPick: @escaping (Int) -> Void) {
        self.index = index
        self.title = title
        self.icon = icon
        self.geom = geom
        self.onPick = onPick
        super.init(frame: frame)
        // layer 相关的设置全在 init 里定死：跟踪过程中切 layer backing
        // 会让 AppKit 重建视图层级，可能打断鼠标跟踪（踩过）。
        wantsLayer = true
        layer?.cornerRadius = kTileRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        // 不画名字的模式（dock）用系统原生悬停提示兜底「这是哪个 App」。
        // 比自绘一个浮层便宜得多，而且和 Dock 自己的名字提示是同一套交互。
        if !geom.showLabel { toolTip = title }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // 关键：允许「第一次点击」就落到本视图上，哪怕 App 不是激活状态
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    /// 悬停底色。浅色模式用极淡的黑、深色模式用极淡的白，
    /// 保证在两种外观下都只是「比背景亮/暗一点点」，不抢图标。
    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var hoverColor: CGColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.09).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        layer?.backgroundColor = hoverColor
        layer?.borderWidth = 0.5
        layer?.borderColor = (isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        // 图标：有名字时垂直略偏上，给下方标签留位置；没名字（dock 模式）时垂直居中，
        // 把整条高度都用上。投影是必要的：Dock 分组面板是半透明毛玻璃，Hermes /
        // DSH 这类白底圆角图标直接放上去边界会糊，有投影轮廓才立得住。
        // 但别给太重 —— 浅色毛玻璃上一圈黑边会显脏。
        let iconRect = NSRect(x: (bounds.width - geom.icon) / 2,
                              y: geom.showLabel ? bounds.height - geom.iconInset - geom.icon
                                                : (bounds.height - geom.icon) / 2,
                              width: geom.icon, height: geom.icon)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4,
                          color: NSColor.black.withAlphaComponent(0.18).cgColor)
            icon.draw(in: iconRect)
            ctx.restoreGState()
        } else {
            icon.draw(in: iconRect)
        }

        // 标签：默认用次级色（浅色模式下是柔和的灰），悬停时才提到正文色。
        // 全用 labelColor 的话，一排纯黑小字压在浅灰毛玻璃上会显得很吵。
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineBreakMode = .byTruncatingTail
        // 标签色：浅色玻璃上走「次级色 → 悬停转正文色」。深色玻璃上不能照搬 ——
        // secondaryLabelColor 在深色模式下是白 55%，压在深灰毛玻璃上会糊成一片，
        // 得手动提亮，否则整排字都看不清。
        // 浅色侧也别直接用 secondaryLabelColor（黑 55%）：压在浅灰毛玻璃上太虚，
        // 一排字像没印实。70% 是「清楚但不抢图标」的平衡点。
        let tone: NSColor
        if isDark {
            tone = NSColor.white.withAlphaComponent(hovered ? 0.98 : 0.78)
        } else {
            tone = NSColor.black.withAlphaComponent(hovered ? 0.92 : 0.70)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: hovered ? .medium : .regular),
            .foregroundColor: tone,
            .paragraphStyle: ps,
        ]
        if geom.showLabel {
            NSAttributedString(string: title, attributes: attrs)
                .draw(in: NSRect(x: 2, y: geom.labelY, width: bounds.width - 4, height: 15))
        }
    }

    override func mouseDown(with event: NSEvent) {
        trace("mouseDown hit item index=\(index) title=\(title)")
        onPick(index)
    }
}

// ─── 主逻辑 ────────────────────────────────────────────────
final class Delegate: NSObject, NSApplicationDelegate {
    private var panel: LauncherPanel?
    private var shown = false
    private var leaving = false
    private var idleTimer: Timer?
    /// 「面板失焦即收起」的观察者。面板重建后要换到新面板上，所以留着引用。
    private var resignObserver: NSObjectProtocol?
    /// 点 Dock 图标展开时记下的图标中心。用来区分「又点了自己这个图标」
    /// 和「点了 Dock 上别的东西」——前者交给 reopen 做切换，后者要收起面板。
    private var anchor = NSPoint.zero

    private var groupName: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupName") as? String) ?? "group"
    }
    private var folderPath: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupFolder") as? String) ?? ""
    }
    private var logDir: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupLogDir") as? String)
            ?? (NSHomeDirectory() + "/Dock Groups/.cache")
    }
    private var materialName: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupMaterial") as? String) ?? "menu"
    }
    /// 网格布局模式：row（默认，长条）/ auto（按应用数自适应）/ 数字（指定列数）/
    /// dock（和 Dock 条等高、不画名字）/ dock-name（同意但让 8pt 给名字）。
    /// 缺失时按 row 处理 —— 兜底要和 dockgroup.py 的 DEFAULT_LAYOUT 一致。
    private var layoutMode: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupLayout") as? String) ?? "row"
    }
    /// dockgroup.py 的绝对路径。GUI 进程的 PATH 只有 /usr/bin:/bin，
    /// 不能指望 `dg` 在 PATH 里，所以由 Info.plist 直接塞绝对路径进来。
    private var scriptPath: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupScript") as? String) ?? ""
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        logPath = logDir + "/\(groupName).launch.log"
        eventLogPath = logDir + "/\(groupName).events.log"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        trace("=== launch pid=\(ProcessInfo.processInfo.processIdentifier) group=\(groupName)")

        let entries = Self.readEntries(folder: folderPath)
        trace("resolved \(entries.count) entries: "
              + entries.map { $0.title }.joined(separator: " / "))

        buildPanel(entries)
        installDismissMonitors()
        showPanel(entries: entries.count)

        // 自检模式：DOCKGROUP_SELFTEST=<下标> 时直接走一次 pick，
        // 用于在无法真实点击的环境里验证「启动」这条链路。
        if let s = ProcessInfo.processInfo.environment["DOCKGROUP_SELFTEST"], let i = Int(s) {
            trace("selftest: picking index \(i)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.pick(i) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.quit() }
        }

        // 渲染模式：DOCKGROUP_RENDER=<png 路径> 时把面板画成图片再退出。
        // 系统不给我们截图权限（screencapture 报 could not create image from rect），
        // 这是唯一能真正「看到」面板长什么样的办法，也是改版式的验证手段。
        if let out = ProcessInfo.processInfo.environment["DOCKGROUP_RENDER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.renderPanelTo(path: out)
                NSApp.terminate(nil)
            }
        }
    }

    /// 把当前面板渲染到 PNG。半透明毛玻璃在离屏渲染里拿不到背后内容，
    /// 所以先铺一层「浅色壁纸 + Dock 条」的底，再叠面板 —— 与实际观感一致。
    private func renderPanelTo(path: String) {
        guard let v = panel?.contentView, v.bounds.width > 1 else {
            trace("render: no panel"); return
        }
        // 先把面板本体画进一张离屏图（毛玻璃会退化成透明，所以下面还要补底）
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            trace("render: no bitmap rep"); return
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        let panelImage = NSImage(size: v.bounds.size)
        panelImage.addRepresentation(rep)

        let m: CGFloat = 40
        let size = NSSize(width: v.bounds.width + m * 2, height: v.bounds.height + m * 2)
        let out = NSImage(size: size)
        out.lockFocus()

        // 底：模拟浅色壁纸 + 一条半透明 Dock 条，贴近真实使用场景
        if let ctx = NSGraphicsContext.current?.cgContext {
            let colors = [NSColor(calibratedRed: 0.45, green: 0.57, blue: 0.74, alpha: 1).cgColor,
                          NSColor(calibratedRed: 0.74, green: 0.68, blue: 0.62, alpha: 1).cgColor]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: .zero,
                                       end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
        NSColor(calibratedWhite: 0.94, alpha: 0.40).setFill()
        NSBezierPath(roundedRect: NSRect(x: 12, y: m - 20, width: size.width - 24, height: 40),
                     xRadius: 13, yRadius: 13).fill()

        // 面板毛玻璃的替身。
        // 离屏渲染拿不到「背后内容」，毛玻璃会退化成全透明，所以这里按材质补一层
        // 等效的底色：浅色材质补浅玻璃，深色材质（hud）补深玻璃 —— 不补的话
        // 预览图里所有材质都长一个样，根本比不出效果。
        // 阴影同理：真机上是窗口阴影，离屏拿不到，不补预览会比实机「平」一大截。
        let glassRect = NSRect(x: m, y: m, width: v.bounds.width, height: v.bounds.height)
        let glass = NSBezierPath(roundedRect: glassRect, xRadius: kPanelRadius,
                                 yRadius: kPanelRadius)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowOffset = NSSize(width: 0, height: -5)
        sh.shadowBlurRadius = 16
        sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
        sh.set()
        if kDarkMaterials.contains(materialName) {
            NSColor(calibratedWhite: 0.16, alpha: 0.84).setFill()
        } else {
            NSColor(calibratedWhite: 0.97, alpha: 0.74).setFill()
        }
        glass.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 再叠面板内容（图标 + 标签；格子底块是画面的主体）
        panelImage.draw(in: glassRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        out.unlockFocus()

        if let tiff = out.tiffRepresentation,
           let pngRep = NSBitmapImageRep(data: tiff),
           let png = pngRep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            trace("render: wrote \(path) size=\(Int(size.width))x\(Int(size.height))")
        }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // 再次点击 Dock 图标：面板开着就收起，收起就展开（相当于切换）
        if panel?.isVisible == true {
            trace("reopen -> toggle close")
            hidePanel()
        } else {
            trace("reopen -> toggle open")
            showPanel(entries: Self.readEntries(folder: folderPath).count)
        }
        return true
    }

    // ── 拖放加入分组：截获 kAEOpenDocuments（拖文件到 Dock 图标上时系统发的事件）
    // application(_:openFile:) 一次只回调一个文件，且两个回调可能同时触发，
    // 所以先攒进集合，0.3s 后统一 flush：多文件不丢、重复事件不重跑。
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleDrop([URL(fileURLWithPath: filename)])
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        handleDrop(urls)
    }

    private var pendingDrops: Set<String> = []
    private var dropFlushTimer: Timer?
    /// 上一次真正提交给 dg add 的路径集合 + 时间。
    /// 实测同一个拖放事件会被系统送两次（有时相隔好几秒），第二次必须丢；
    /// 光靠 0.3s 的合并窗口挡不住。
    private var lastFlushed: (paths: [String], at: Date) = ([], .distantPast)

    func handleDrop(_ urls: [URL]) {
        let apps = urls.filter { $0.pathExtension.lowercased() == "app" }
        if urls.count > apps.count {
            trace("drop: ignored \(urls.count - apps.count) non-app item(s)")
        }
        guard !apps.isEmpty else { return }

        for a in apps { pendingDrops.insert(a.path) }
        dropFlushTimer?.invalidate()
        dropFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) {
            [weak self] _ in self?.flushDrops()
        }
    }

    private func flushDrops() {
        let paths = pendingDrops.sorted()
        pendingDrops.removeAll()
        guard !paths.isEmpty else { return }

        // 同一批路径短期内重复到达 → 丢掉
        if paths == lastFlushed.paths,
           Date().timeIntervalSince(lastFlushed.at) < 10 {
            trace("drop: duplicate batch ignored (same \(paths.count) path(s))")
            return
        }
        lastFlushed = (paths, Date())

        trace("drop: add \(paths.count) app(s): "
              + paths.map { ($0 as NSString).lastPathComponent }
                     .joined(separator: " / "))
        runAdd(paths)
    }

    /// 跑引擎的 add，走和命令行完全一样的链路（建别名 → 刷新图标 → 重启 Dock）。
    ///
    /// 引擎入口有两种形态：dockgroup.py（要经 /usr/bin/python3）和 dg 二进制 /
    /// 带 shebang 的 shim（直接 exec）—— 用后缀区分。
    private func runAdd(_ paths: [String]) {
        guard !scriptPath.isEmpty else {
            trace("add aborted: DockGroupScript missing in Info.plist")
            return
        }
        let isPython = scriptPath.hasSuffix(".py")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: isPython ? "/usr/bin/python3" : scriptPath)
        task.arguments = isPython ? [scriptPath, "add", groupName] + paths
                                  : ["add", groupName] + paths
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            trace("add failed to spawn engine: \(error.localizedDescription)")
            return
        }
        task.terminationHandler = { [weak self] t in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            trace("add exit=\(t.terminationStatus) "
                  + "out=\(out.replacingOccurrences(of: "\n", with: " | "))")
            DispatchQueue.main.async { self?.afterAdd(ok: t.terminationStatus == 0) }
        }
    }

    /// 加成功后：面板开着就刷新网格，新 App 立刻出现（位置保持不动）。
    private func afterAdd(ok: Bool) {
        guard ok else { return }
        guard let p = panel, p.isVisible else { return }
        let origin = p.frame.origin
        let entries = Self.readEntries(folder: folderPath)
        buildPanel(entries)
        if let np = panel {
            np.setFrameOrigin(origin)
            np.makeKeyAndOrderFront(nil)
            // 重建后要重新确认状态：buildPanel 里关旧面板会触发失焦回调，
            // 把 shown 置成 false —— 不重置的话新面板就永远收不起来了。
            shown = true
            cancelIdleExit()
        }
        // 窗口数应当恒为 1。>1 就说明又留下孤儿窗口了（就是「关不掉」那个 bug）。
        trace("after refresh: windows=\(NSApp.windows.count) entries=\(entries.count)")
        logWindows()
        trace("panel refreshed with \(entries.count) entries")
    }

    /// 把当前所有窗口列进日志：类名 + 可见性 + 层级。
    /// 排查「有个窗口关不掉」时，这是唯一能看清到底还剩几个窗口的办法。
    private func logWindows() {
        for w in NSApp.windows {
            trace("  window \(type(of: w)) num=\(w.windowNumber) "
                  + "visible=\(w.isVisible) level=\(w.level.rawValue) "
                  + "frame=\(NSStringFromRect(w.frame))")
        }
    }

    // 读分组文件夹，解析别名 → 真实 App
    static func readEntries(folder: String) -> [Entry] {
        let fm = FileManager.default
        guard !folder.isEmpty,
              let names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        var out: [Entry] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if name.hasPrefix(".") || name.contains("\r") { continue }
            let raw = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let target = (try? URL(resolvingAliasFileAt: raw)) ?? raw
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard target.pathExtension.lowercased() == "app" else { continue }
            var title = name
            if title.hasSuffix(".app") { title = String(title.dropLast(4)) }
            out.append(Entry(title: title, path: target.path))
        }
        return out
    }

    // ── 构建面板
    /// 把无边框窗口裁成圆角。
    ///
    /// 为什么不能只在 contentView 上设 cornerRadius：窗口的形状判定和阴影计算
    /// 都在 theme frame（contentView 的 superview）那一层。只设 contentView 时
    /// 自己画的像素是圆角的，但窗口阴影 + behindWindow 毛玻璃仍按**矩形**算，
    /// 四个角就会各露出一小块直角 —— 就是「四角有尖尖的一块」。
    /// 设完必须 invalidateShadow()，否则系统还在用按旧形状生成的阴影贴图。
    private func roundWindow(_ w: NSWindow, radius: CGFloat) {
        w.isOpaque = false
        w.backgroundColor = .clear
        guard let content = w.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        if let frame = content.superview {
            frame.wantsLayer = true
            frame.layer?.cornerRadius = radius
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
        }
        w.invalidateShadow()
        trace("roundWindow: content radius=\(content.layer?.cornerRadius ?? -1) "
              + "themeFrame radius=\(content.superview?.layer?.cornerRadius ?? -1) "
              + "hasShadow=\(w.hasShadow)")
    }

    /// 给毛玻璃生成一张圆角遮罩图。
    ///
    /// `NSVisualEffectView.maskImage` 是唯一能裁掉 `.behindWindow` 那层模糊的
    /// 公开手段 —— 那层模糊是窗口服务器画的，位于 layer 内容之下，
    /// 设 cornerRadius / masksToBounds 都够不着它，四角照样是直角。
    /// 规则：遮罩图**不透明**的地方才显示毛玻璃。
    private func roundedMask(size: NSSize, radius: CGFloat) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: radius, yRadius: radius).fill()
        img.unlockFocus()
        return img
    }

    private func buildPanel(_ entries: [Entry]) {
        // 重建前先把旧面板的失焦回调摘掉再关它 —— 否则那次关闭会触发
        // hidePanel()，把 shown 置 false / 排一个空闲退出，把状态搅乱。
        if let old = resignObserver {
            NotificationCenter.default.removeObserver(old)
            resignObserver = nil
        }
        // 旧面板必须彻底 close：只 orderOut 的话窗口还在，
        // 而关闭回调指向的是 self.panel（新面板），旧窗口就成了「关不掉的窗」。
        if let old = panel {
            old.close()
            trace("buildPanel: closed previous panel, windows=\(NSApp.windows.count)")
        }

        let n = max(entries.count, 1)
        let cols = columns(for: n, layout: layoutMode)
        let rows = Int(ceil(Double(n) / Double(cols)))
        let geom = geometry(for: layoutMode)
        let size = geom.panelSize(cols: cols, rows: rows)
        let w = size.width, h = size.height

        let p = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // 面板由 self.panel 强引用着；若让系统在 close 后再 release 一次，
        // 就成了野指针（关闭时机是「当前事件结束后」，很难复现）。这里明确不托管。
        p.isReleasedWhenClosed = false
        // 注意：NSPanel.isFloatingPanel = true 会把 level 重置为 3（NSFloatingWindowLevel），
        // 而 Dock 的层级是 20 —— 那样面板会被 Dock 压住。所以这里只显式设 level，
        // 绝不碰 isFloatingPanel。
        p.level = .popUpMenu          // 101，高于 Dock 的 20
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

        let bg = DropVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        // 材质与外观的判定最容易出现「改了不生效」，落一行日志方便对账：
        // 面板真机发白时，先看这行是 material 不对还是 appearance 没跟上。
        // 布局同理：网格不对时先看这行的 layout / grid / size 对不对，
        // 能立刻区分「配置没传进来」「列数算错」和「二进制压根没换」。
        trace("panel: layout=[\(layoutMode)] entries=\(n) grid=\(cols)x\(rows) "
              + "size=\(Int(w))x\(Int(h)) cell=\(Int(geom.cellW))x\(Int(geom.cellH)) "
              + "icon=\(Int(geom.icon)) label=\(geom.showLabel) "
              + "material=[\(materialName)] dark=\(kDarkMaterials.contains(materialName)) "
              + "window=\(p.effectiveAppearance.name.rawValue)")
        // 深色材质必须把 appearance 设在「毛玻璃视图自己」身上。
        // 只在 NSWindow 上设 p.appearance 是不够的 —— 实测那样 hud 依然渲染成
        // 浅色玻璃、标签照旧是黑的，整块面板跟 menu 没区别（踩过，靠真机区域截图才发现）。
        // 材质是在视图加入层级时就按当时的外观解析好的，view 自己带外观才吃得准。
        if kDarkMaterials.contains(materialName) {
            bg.appearance = NSAppearance(named: .darkAqua)
        }
        bg.material = material(named: materialName)
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        // 圆角跟着格子的观感走：26pt + 连续曲率，接近系统 popover 的手感。
        // 注意这层只裁得到 bg 自己画的像素 —— 窗口级那层毛玻璃和窗口阴影
        // 归 theme frame 管，必须再调 roundWindow()，否则四角会露出直角块（踩过）。
        bg.layer?.cornerRadius = kPanelRadius
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        // 描边要跟着外观走：浅色模式下白描边等于没有，面板边界会糊掉。
        bg.layer?.borderColor = NSColor(name: nil) { app in
            app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.10)
        }.cgColor
        // 毛玻璃那层圆角只能靠 maskImage 裁：它画在 layer 内容之下，
        // cornerRadius / masksToBounds 都够不着 —— 漏了这句四角就是直角块。
        bg.maskImage = roundedMask(size: NSSize(width: w, height: h), radius: kPanelRadius)
        bg.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        // 点面板空白处 = 关掉面板（除图标格子外的区域）
        bg.onEmptyClick = { [weak self] in
            trace("dismiss: click on panel background")
            self?.hidePanel()
        }
        p.contentView = bg
        // 圆角必须一路设到 theme frame（contentView 的 superview）才有效 ——
        // 只设 contentView 的话，窗口阴影和 behindWindow 那层毛玻璃仍然是矩形，
        // 四个角就会各露出一个直角块（「四角有尖尖的一块」就是这个）。
        roundWindow(p, radius: kPanelRadius)

        // 边缘高光：叠在毛玻璃之上、图标格子之下（子视图后加的在上，所以先加它）
        let shine = ShineView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        shine.radius = kPanelRadius
        shine.autoresizingMask = [.width, .height]
        bg.addSubview(shine)

        for (i, item) in entries.enumerated() {
            let r = i / cols, c = i % cols
            // 每行独立居中：最后一行不满时也居中，不然会甩在左边很难看
            let inRow = min(cols, n - r * cols)
            let rowW = CGFloat(inRow) * geom.cellW + CGFloat(inRow - 1) * geom.gap
            let x = (w - rowW) / 2 + CGFloat(c) * (geom.cellW + geom.gap)
            let y = h - geom.pad - CGFloat(r + 1) * geom.cellH - CGFloat(r) * geom.gap
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            icon.size = NSSize(width: geom.icon, height: geom.icon)
            let view = ItemView(index: i, title: item.title, icon: icon, geom: geom,
                                frame: NSRect(x: x, y: y, width: geom.cellW,
                                              height: geom.cellH)) {
                [weak self] idx in self?.pick(idx)
            }
            bg.addSubview(view)
        }
        p.onCancel = { [weak self] in self?.hidePanel() }
        panel = p
        // 失焦即收起的监听必须挂到「当前这个」面板上。
        // 挂在初始面板上、重建后不重建监听 → 新面板永远收不起来（就是「关不掉」）。
        wireResignDismiss(to: p)
    }

    /// 把「面板失焦 → 收起」挂到指定面板。重建面板后必须重新挂一次。
    private func wireResignDismiss(to p: LauncherPanel) {
        if let old = resignObserver {
            NotificationCenter.default.removeObserver(old)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in
            guard let self, self.shown else { return }
            trace("dismiss: panel resigned key")
            self.hidePanel()
        }
    }

    // ── 定位并显示：Dock 图标正上方，水平居中对齐
    private func showPanel(entries: Int?) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation            // 点击瞬间 ≈ 刚被点的 Dock 图标中心
        anchor = m                               // 记下锚点，供全局监听区分「点自己」还是「点别处」
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        let full = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let vis = screen?.visibleFrame ?? full   // 已经排除 Dock 和菜单栏

        // 水平：以图标中心对齐，并限制在可用区内（侧边 Dock 时也不会被压住）
        var x = m.x - p.frame.width / 2
        x = min(max(x, vis.minX + 8), vis.maxX - p.frame.width - 8)

        // 垂直：优先贴在图标正上方；若会压到 Dock，就整体抬到 Dock 上沿之上
        var y = m.y + 14
        y = max(y, vis.minY + 8)
        if y + p.frame.height > vis.maxY - 8 { y = vis.maxY - 8 - p.frame.height }
        if y < full.minY + 8 { y = full.minY + 8 }

        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.makeKeyAndOrderFront(nil)
        shown = true
        cancelIdleExit()
        trace("panel shown frame=\(NSStringFromRect(p.frame)) "
              + "level=\(p.level.rawValue) key=\(p.isKeyWindow)")
        writeState(frame: p.frame, screen: full, visible: vis, count: entries ?? 0)
    }

    // ── 关闭方式：点击面板外 / 失焦
    // 全局监听只装一次，内部永远读「当前」的 self.panel，所以重建面板不需要重装。
    private func installDismissMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.shown, let p = self.panel else { return }
            let m = NSEvent.mouseLocation

            // 全局监视器按理收不到自己窗口的事件；万一路径异常收到，
            // 也要保证面板内部的点击不会被当成「点外面」而误收起。
            if p.frame.contains(m) {
                trace("global monitor fired INSIDE panel frame -> ignored")
                return
            }

            // 点在 Dock 条上：只有点在**我们自己这个图标**附近时才放行，
            // 交给 Dock 发 reopen 做「展开/收起」切换。
            // 早期这里是「Dock 条上一律忽略」，结果点 Dock 上任何别的地方
            // 面板都不收 —— 面板层级 101 压在所有窗口之上，就成了关不掉的窗。
            let inDockStrip = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }
                .map { !NSMouseInRect(m, $0.visibleFrame, false) } ?? false
            if inDockStrip {
                let dx = abs(m.x - anchor.x), dy = abs(m.y - anchor.y)
                if dx <= 44 && dy <= 60 {
                    trace("global monitor: click on own dock tile -> ignored (let reopen toggle)")
                    return
                }
                trace("global monitor: click elsewhere in Dock strip -> dismiss")
            } else {
                trace("dismiss: click outside panel")
            }
            self.hidePanel()
        }
    }

    // ── 选中某一项：启动对应 App
    private func pick(_ index: Int) {
        let entries = Self.readEntries(folder: folderPath)
        trace("pick index=\(index) entries=\(entries.count)")
        guard index >= 0, index < entries.count else {
            trace("pick out of range, abort")
            hidePanel()
            return
        }
        let url = URL(fileURLWithPath: entries[index].path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            trace("target missing: \(url.path)")
            hidePanel()
            return
        }

        trace("launching \(url.path)")
        hidePanel()          // 面板立刻收起，不等回调
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
            trace("openApplication result app=\(app?.localizedName ?? "nil") "
                  + "pid=\(app?.processIdentifier ?? -1) "
                  + "err=\(err?.localizedDescription ?? "nil")")
        }
    }

    // ── 收起面板（进程留着，等空闲超时再退）
    func hidePanel() {
        guard let p = panel else { return }
        shown = false
        p.orderOut(nil)
        trace("panel hidden")
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: kIdleSeconds, repeats: false) { [weak self] _ in
            self?.quit()
        }
    }

    private func cancelIdleExit() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func quit() {
        guard !leaving else { return }
        leaving = true
        cancelIdleExit()
        trace("=== exit")
        NSApp.terminate(nil)
    }

    // ── 面板几何状态（供外部脚本校验定位）
    private func writeState(frame: NSRect, screen: NSRect, visible: NSRect, count: Int) {
        let payload: [String: Any] = [
            "group": groupName,
            "count": count,
            "level": panel?.level.rawValue ?? -1,
            "dockLevel": CGWindowLevelForKey(.dockWindow),
            "clearsDock": frame.minY >= visible.minY,
            "frame": ["x": frame.origin.x, "y": frame.origin.y,
                      "w": frame.width, "h": frame.height],
            "visible": ["x": visible.origin.x, "y": visible.origin.y,
                        "w": visible.width, "h": visible.height],
            "screen": ["x": screen.origin.x, "y": screen.origin.y,
                       "w": screen.width, "h": screen.height],
            "onScreen": screen.contains(NSPoint(x: frame.midX, y: frame.midY)),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}

// ─── 入口 ──────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
