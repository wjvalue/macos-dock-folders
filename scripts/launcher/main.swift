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
let kIcon: CGFloat = 56
let kCellW: CGFloat = 84
let kCellH: CGFloat = 90
let kPad: CGFloat = 16
let kGap: CGFloat = 4

struct Entry {
    let title: String
    let path: String
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

// ─── 面板 ──────────────────────────────────────────────────
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        trace("dismiss: Esc")
        NSApp.terminate(nil)
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
    private let onPick: (Int) -> Void
    private var area: NSTrackingArea?

    init(index: Int, title: String, icon: NSImage, frame: NSRect,
         onPick: @escaping (Int) -> Void) {
        self.index = index
        self.title = title
        self.icon = icon
        self.onPick = onPick
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.clear.cgColor
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

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let iconY = bounds.height - 8 - kIcon
        icon.draw(in: NSRect(x: (bounds.width - kIcon) / 2, y: iconY,
                             width: kIcon, height: kIcon))

        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: ps,
        ]
        NSAttributedString(string: title, attributes: attrs)
            .draw(in: NSRect(x: 2, y: 4, width: bounds.width - 4, height: 15))
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
    private var finished = false

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
        }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel(entries: nil)   // 已在运行时再次点击 Dock 图标
        return true
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
    private func buildPanel(_ entries: [Entry]) {
        let n = max(entries.count, 1)
        let cols = min(4, n)
        let rows = Int(ceil(Double(n) / Double(cols)))
        let w = kPad * 2 + CGFloat(cols) * kCellW + CGFloat(cols - 1) * kGap
        let h = kPad * 2 + CGFloat(rows) * kCellH + CGFloat(rows - 1) * kGap

        let p = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // 注意：NSPanel.isFloatingPanel = true 会把 level 重置为 3（NSFloatingWindowLevel），
        // 而 Dock 的层级是 20 —— 那样面板会被 Dock 压住。所以这里只显式设 level，
        // 绝不碰 isFloatingPanel。
        p.level = .popUpMenu          // 101，高于 Dock 的 20
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        p.contentView = bg

        for (i, item) in entries.enumerated() {
            let r = i / cols, c = i % cols
            let x = kPad + CGFloat(c) * (kCellW + kGap)
            let y = h - kPad - CGFloat(r + 1) * kCellH - CGFloat(r) * kGap
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            icon.size = NSSize(width: kIcon, height: kIcon)
            let view = ItemView(index: i, title: item.title, icon: icon,
                                frame: NSRect(x: x, y: y, width: kCellW, height: kCellH)) {
                [weak self] idx in self?.pick(idx)
            }
            bg.addSubview(view)
        }
        panel = p
    }

    // ── 定位并显示：Dock 图标正上方，水平居中对齐
    private func showPanel(entries: Int?) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation            // 点击瞬间 ≈ 刚被点的 Dock 图标中心
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
        trace("panel shown frame=\(NSStringFromRect(p.frame)) "
              + "level=\(p.level.rawValue) key=\(p.isKeyWindow)")
        writeState(frame: p.frame, screen: full, visible: vis, count: entries ?? 0)
    }

    // ── 关闭方式：点击面板外 / 失焦
    private func installDismissMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let p = self.panel else { return }
            // 全局监视器按理收不到自己窗口的事件；万一路径异常收到，
            // 也要保证面板内部的点击不会被当成「点外面」而误退出。
            if p.frame.contains(NSEvent.mouseLocation) {
                trace("global monitor fired INSIDE panel frame -> ignored")
                return
            }
            trace("dismiss: click outside panel")
            self.finish()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.shown, !self.finished else { return }
            trace("dismiss: panel resigned key")
            self.finish()
        }
    }

    // ── 选中某一项：启动对应 App
    private func pick(_ index: Int) {
        let entries = Self.readEntries(folder: folderPath)
        trace("pick index=\(index) entries=\(entries.count)")
        guard index >= 0, index < entries.count else {
            trace("pick out of range, abort")
            finish()
            return
        }
        let url = URL(fileURLWithPath: entries[index].path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            trace("target missing: \(url.path)")
            finish()
            return
        }

        trace("launching \(url.path)")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
            trace("openApplication result app=\(app?.localizedName ?? "nil") "
                  + "pid=\(app?.processIdentifier ?? -1) "
                  + "err=\(err?.localizedDescription ?? "nil")")
            DispatchQueue.main.async { self.finish() }
        }
        // 兜底：万一回调不来，也不能把面板留在屏幕上
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
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
