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
let kMaxCols = 4

struct Entry {
    let title: String
    let path: String
}

// ─── 面板 ──────────────────────────────────────────────────
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { NSApp.terminate(nil) }  // Esc
}

// ─── 带悬停高亮的图标按钮 ──────────────────────────────────
final class IconButton: NSButton {
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// ─── 主逻辑 ────────────────────────────────────────────────
final class Delegate: NSObject, NSApplicationDelegate {
    private var panel: LauncherPanel?
    private var shown = false

    private var groupName: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupName") as? String) ?? "group"
    }
    private var folderPath: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupFolder") as? String) ?? ""
    }
    /// 日志目录由 Info.plist 注入（跟着 DOCKGROUP_HOME 走），仅在缺失时回落
    private var logDir: String {
        (Bundle.main.object(forInfoDictionaryKey: "DockGroupLogDir") as? String)
            ?? (NSHomeDirectory() + "/Dock Groups/.cache")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let entries = Self.readEntries(folder: folderPath)
        buildPanel(entries)
        installDismissMonitors()
        showPanel(entries: entries.count)
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
        let cols = min(kMaxCols, n)
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
            let b = IconButton(frame: NSRect(x: x, y: y, width: kCellW, height: kCellH))
            b.isBordered = false
            b.bezelStyle = .inline
            b.imagePosition = .imageAbove
            b.imageScaling = .scaleProportionallyUpOrDown
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            icon.size = NSSize(width: kIcon, height: kIcon)
            b.image = icon
            b.title = item.title
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = .labelColor
            b.toolTip = item.path
            b.target = self
            b.action = #selector(launch(_:))
            b.tag = i
            bg.addSubview(b)
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
        writeLog(frame: p.frame, screen: full, visible: vis, count: entries ?? 0)
    }

    // ── 关闭方式：点击别处 / 失焦
    private func installDismissMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            NSApp.terminate(nil)
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.shown else { return }
            NSApp.terminate(nil)
        }
    }

    @objc private func launch(_ sender: NSButton) {
        let entries = Self.readEntries(folder: folderPath)
        guard sender.tag >= 0, sender.tag < entries.count else { NSApp.terminate(nil); return }
        let url = URL(fileURLWithPath: entries[sender.tag].path)
        panel?.orderOut(nil)
        NSWorkspace.shared.open(url)
        NSApp.terminate(nil)
    }

    // ── 写日志，方便外部验证（无 GUI 权限时的可观测手段）
    private func writeLog(frame: NSRect, screen: NSRect, visible: NSRect, count: Int) {
        let dir = logDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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
            try? data.write(to: URL(fileURLWithPath: dir + "/\(groupName).launch.log"))
        }
    }
}

// ─── 入口 ──────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
