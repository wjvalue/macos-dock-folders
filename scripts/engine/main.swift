// DockGroup Native Engine
//
// 原生 Swift 运行引擎：负责配置、图标合成、分组别名、Dock 同步和启动器构建。
// 它替代运行期的 Python + Pillow；AppKit 直接读取系统图标并输出 PNG/ICNS。

import AppKit
import Foundation

let engineVersion = "2.0.0"

// ─── 路径与进程 ────────────────────────────────────────────

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let base: URL = {
        if let value = ProcessInfo.processInfo.environment["DOCKGROUP_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Dock Groups")
    }()

    static let cache = base.appendingPathComponent(".cache")
    static let backup = base.appendingPathComponent(".backup")
    static let apps = base.appendingPathComponent(".apps")
    static let config = base.appendingPathComponent("groups.json")

    static var sourceRoot: URL? {
        if let value = ProcessInfo.processInfo.environment["DOCKGROUP_SOURCE_ROOT"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("engine-resources"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    static var launcherSource: URL? {
        sourceRoot?.appendingPathComponent("launcher/main.swift")
    }

    static var managerSource: URL? {
        sourceRoot?.appendingPathComponent("manager/main.swift")
    }
}

@discardableResult
func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var merged = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        merged[key] = value
    }
    process.environment = merged
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        fputs("无法执行 \(executable)：\(error.localizedDescription)\n", stderr)
        return -1
    }
}

func output(_ text: String) {
    print(text)
}

func fail(_ text: String) -> Never {
    fputs("❌ \(text)\n", stderr)
    exit(1)
}

// ─── 配置 ──────────────────────────────────────────────────

struct Group: Codable {
    var name: String
    var enabled: Bool = true
    var placement: String? = "left"
    var after: String?
    var apps: [String] = []
    var style: String?
    var material: String?
    var layout: String?

    enum CodingKeys: String, CodingKey {
        case name, enabled, placement, after, apps, style, material, layout
    }

    init(name: String, apps: [String] = []) {
        self.name = name
        self.apps = apps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        placement = try? container.decode(String.self, forKey: .placement)
        after = try? container.decode(String.self, forKey: .after)
        apps = (try? container.decode([String].self, forKey: .apps)) ?? []
        style = try? container.decode(String.self, forKey: .style)
        material = try? container.decode(String.self, forKey: .material)
        layout = try? container.decode(String.self, forKey: .layout)
    }
}

struct Config: Codable {
    var style: String = "graphite"
    var groups: [Group] = []
    var material: String = "hud"
    var layout: String = "row"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? container.decode(String.self, forKey: .style)) ?? "graphite"
        groups = (try? container.decode([Group].self, forKey: .groups)) ?? []
        material = (try? container.decode(String.self, forKey: .material)) ?? "hud"
        layout = (try? container.decode(String.self, forKey: .layout)) ?? "row"
    }
}

/// 读取用户配置；缺少文件或字段时回退到默认值，保证首次运行可直接进入 CLI。
func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: Paths.config) else { return Config() }
    return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
}

func jsonQuote(_ value: String) -> String {
    let data = try! JSONEncoder().encode(value)
    return String(data: data, encoding: .utf8)!
}

func jsonText(_ config: Config) -> String {
    var text = "{\n"
    text += "  \"style\": \(jsonQuote(config.style)),\n"
    text += "  \"groups\": ["
    if !config.groups.isEmpty {
        text += "\n"
        text += config.groups.enumerated().map { index, group in
            var fields = [
                "    \"name\": \(jsonQuote(group.name))",
                "    \"enabled\": \(group.enabled)"
            ]
            if let value = group.placement { fields.append("    \"placement\": \(jsonQuote(value))") }
            if let value = group.after { fields.append("    \"after\": \(jsonQuote(value))") }
            let apps = group.apps.map { "      \(jsonQuote($0))" }.joined(separator: ",\n")
            fields.append(apps.isEmpty ? "    \"apps\": []" : "    \"apps\": [\n\(apps)\n    ]")
            if let value = group.style { fields.append("    \"style\": \(jsonQuote(value))") }
            if let value = group.material { fields.append("    \"material\": \(jsonQuote(value))") }
            if let value = group.layout { fields.append("    \"layout\": \(jsonQuote(value))") }
            return "  {\n\(fields.joined(separator: ",\n"))\n  }" + (index + 1 == config.groups.count ? "" : ",")
        }.joined(separator: "\n")
        text += "\n  "
    }
    text += "],\n"
    text += "  \"material\": \(jsonQuote(config.material)),\n"
    text += "  \"layout\": \(jsonQuote(config.layout))\n"
    text += "}\n"
    return text
}

/// 以稳定的 JSON 结构写回配置，确保 GUI 与 CLI 共享同一份事实来源。
func saveConfig(_ config: Config) {
    do {
        try FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        try jsonText(config).write(to: Paths.config, atomically: true, encoding: .utf8)
    } catch {
        fail("写入配置失败：\(error.localizedDescription)")
    }
}

func groupIndex(_ config: Config, name: String) -> Int? {
    config.groups.firstIndex { $0.name == name }
}

func groupOrFail(_ config: Config, name: String) -> Group {
    guard let group = config.groups.first(where: { $0.name == name }) else {
        fail("没有分组「\(name)」")
    }
    return group
}

// ─── App 与别名 ────────────────────────────────────────────

func resolveAlias(_ url: URL) -> URL {
    if let data = try? Data(contentsOf: url) {
        var stale = false
        if let bookmark = try? URL(resolvingBookmarkData: data,
                                   options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil,
                                   bookmarkDataIsStale: &stale) {
            return bookmark
        }
    }
    return (try? URL(resolvingAliasFileAt: url)) ?? url
}

/// 读取分组目录并解析 Finder bookmark 别名；真实 App 与别名都会返回，但标记来源。
func appEntries(in folder: URL) -> [(name: String, target: URL, alias: Bool)] {
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isDirectoryKey, .isAliasFileKey],
        options: [.skipsHiddenFiles]) else { return [] }

    return urls.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }.compactMap { item in
        guard !item.lastPathComponent.contains("\r") else { return nil }
        let target = resolveAlias(item)
        guard target.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: target.path) else { return nil }
        let name = item.deletingPathExtension().lastPathComponent
        let alias = target.path != item.path
        return (name, target, alias)
    }
}

func appDirectories() -> [URL] {
    return [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        Paths.home.appendingPathComponent("Applications")
    ]
}

func resolveApp(_ spec: String) -> URL? {
    let direct = URL(fileURLWithPath: (spec as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: direct.path) { return direct }
    let needle = spec.hasSuffix(".app") ? String(spec.dropLast(4)) : spec
    let lower = needle.lowercased()
    for directory in appDirectories() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { continue }
        if let exact = items.first(where: {
            $0.pathExtension == "app"
                && $0.deletingPathExtension().lastPathComponent.lowercased() == lower
        }) {
            return exact
        }
        if let fuzzy = items.first(where: {
            $0.pathExtension == "app"
                && $0.deletingPathExtension().lastPathComponent.lowercased().contains(lower)
        }) {
            return fuzzy
        }
    }
    return NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: needle))
}

/// 创建 Finder 可识别的 bookmark 别名，不移动用户的真实 App 文件。
func addAlias(from source: URL, to folder: URL) throws {
    let name = source.deletingPathExtension().lastPathComponent
    let destination = folder.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: destination.path) else { return }
    let bookmark = try source.bookmarkData(options: .suitableForBookmarkFile,
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
    try bookmark.write(to: destination, options: .atomic)
}

// ─── 原生图标合成 ──────────────────────────────────────────

struct Style {
    let top: NSColor
    let bottom: NSColor
    let edge: NSColor
    let cell: CGFloat
    let pad: CGFloat
    let gap: CGFloat
    let shadow: Bool
}

let styles: [String: Style] = [
    "graphite": Style(
        top: NSColor(calibratedWhite: 0.22, alpha: 0.99),
        bottom: NSColor(calibratedWhite: 0.10, alpha: 0.99),
        edge: NSColor.white.withAlphaComponent(0.18), cell: 0.44,
        pad: 0.085, gap: 0.045, shadow: true
    ),
    "glass-dark": Style(
        top: NSColor(calibratedWhite: 0.20, alpha: 0.96),
        bottom: NSColor(calibratedWhite: 0.08, alpha: 0.96),
        edge: NSColor.white.withAlphaComponent(0.16), cell: 0.44,
        pad: 0.085, gap: 0.045, shadow: true
    ),
    "dock": Style(
        top: NSColor(calibratedRed: 0.88, green: 0.89, blue: 0.93, alpha: 0.99),
        bottom: NSColor(calibratedRed: 0.78, green: 0.79, blue: 0.84, alpha: 0.99),
        edge: NSColor.black.withAlphaComponent(0.20), cell: 0.44,
        pad: 0.085, gap: 0.045, shadow: true
    ),
    "dock-deep": Style(
        top: NSColor(calibratedRed: 0.82, green: 0.83, blue: 0.87, alpha: 0.99),
        bottom: NSColor(calibratedRed: 0.69, green: 0.71, blue: 0.76, alpha: 0.99),
        edge: NSColor.black.withAlphaComponent(0.22), cell: 0.44,
        pad: 0.085, gap: 0.045, shadow: true
    ),
    "paper": Style(
        top: .white, bottom: NSColor(calibratedWhite: 0.93, alpha: 1),
        edge: NSColor.black.withAlphaComponent(0.12), cell: 0.44,
        pad: 0.085, gap: 0.045, shadow: true
    ),
    "frost-light": Style(
        top: NSColor.white.withAlphaComponent(0.88),
        bottom: NSColor(calibratedWhite: 0.82, alpha: 0.88),
        edge: NSColor.black.withAlphaComponent(0.12), cell: 0.44,
        pad: 0.085, gap: 0.045, shadow: true
    ),
    "frost-blue": Style(
        top: NSColor(calibratedRed: 0.73, green: 0.84, blue: 0.98, alpha: 0.94),
        bottom: NSColor(calibratedRed: 0.39, green: 0.55, blue: 0.80, alpha: 0.94),
        edge: NSColor.white.withAlphaComponent(0.24), cell: 0.44,
        pad: 0.085, gap: 0.045, shadow: true
    ),
]

let materials: Set<String> = [
    "hud", "menu", "sidebar", "header", "popover", "titlebar", "underWindow",
    "contentBackground", "sheet", "windowBackground", "appearanceBased",
    "fullScreenUI", "toolTip"
]

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DockGroup", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG"])
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func appIcon(_ app: URL) -> NSImage {
    NSWorkspace.shared.icon(forFile: app.path)
}

func roundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// 用 AppKit 直接读取系统图标并合成 PNG，替代 Pillow 的缩放、渐变和投影流程。
func mosaic(for apps: [URL], styleName: String, output: URL) throws {
    let style = styles[styleName] ?? styles["graphite"]!
    let size: CGFloat = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.075
    let box = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = box.width * 0.235
    if style.shadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.36)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.withAlphaComponent(0.35).setFill()
        roundedPath(box.insetBy(dx: 12, dy: 12), radius: radius - 10).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    if let gradient = NSGradient(starting: style.top, ending: style.bottom) {
        gradient.draw(in: roundedPath(box, radius: radius), angle: -90)
    }
    style.edge.setStroke()
    let border = roundedPath(box.insetBy(dx: 2, dy: 2), radius: radius - 2)
    border.lineWidth = 5
    border.stroke()

    let side = box.width
    var cell = side * style.cell
    var slots: [NSPoint]
    if apps.count == 1 {
        cell = side * 0.62
        slots = [NSPoint(x: box.minX + (side - cell) / 2, y: box.minY + (side - cell) / 2)]
    } else if apps.count == 2 {
        cell = side * 0.55
        let gap = side * 0.08
        let x = box.minX + (side - cell * 2 - gap) / 2
        slots = [
            NSPoint(x: x, y: box.minY + (side - cell) / 2),
            NSPoint(x: x + cell + gap, y: box.minY + (side - cell) / 2)
        ]
    } else {
        let pad = side * style.pad
        let gap = side * style.gap
        slots = [
            NSPoint(x: box.minX + pad, y: box.minY + pad),
            NSPoint(x: box.minX + pad + cell + gap, y: box.minY + pad),
            NSPoint(x: box.minX + pad, y: box.minY + pad + cell + gap),
            NSPoint(
                x: box.minX + pad + cell + gap,
                y: box.minY + pad + cell + gap
            )
        ]
    }

    for (index, app) in apps.prefix(4).enumerated() {
        let frame = NSRect(origin: slots[index], size: NSSize(width: cell, height: cell))
        let icon = appIcon(app)
        if style.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -5)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    try writePNG(image, to: output)
}

func iconForGroup(_ group: Group, style: String, previewOnly: Bool = false) -> (URL, [(String, URL, Bool)]) {
    let folder = Paths.base.appendingPathComponent(group.name)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if appEntries(in: folder).isEmpty && !previewOnly {
        for value in group.apps {
            if let app = resolveApp(value) { try? addAlias(from: app, to: folder) }
        }
    }
    let entries = appEntries(in: folder)
    let valid = entries.filter { FileManager.default.fileExists(atPath: $0.target.path) }
    guard !valid.isEmpty else { fail("分组「\(group.name)」里没有任何 App") }
    let output = Paths.cache.appendingPathComponent("\(group.name).png")
    do {
        try mosaic(for: valid.map(\.target), styleName: style, output: output)
        if !previewOnly {
            if let image = NSImage(contentsOf: output) {
                _ = NSWorkspace.shared.setIcon(image, forFile: folder.path, options: [])
            }
        }
    } catch {
        fail("合成「\(group.name)」图标失败：\(error.localizedDescription)")
    }
    return (output, valid)
}

// ─── Dock plist ────────────────────────────────────────────

let dockDomain = "com.apple.dock"
let launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    + "LaunchServices.framework/Support/lsregister"

func captured(_ executable: String, _ arguments: [String], input: Data? = nil) -> (status: Int32, data: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    if let input {
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(input)
            inputPipe.fileHandleForWriting.closeFile()
        } catch { return (-1, Data()) }
    } else {
        do { try process.run() } catch { return (-1, Data()) }
    }
    process.waitUntilExit()
    return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
}

func dockRead() -> [String: Any] {
    let result = captured("/usr/bin/defaults", ["export", dockDomain, "-"])
    guard result.status == 0,
          let value = try? PropertyListSerialization.propertyList(from: result.data, options: [], format: nil),
          let plist = value as? [String: Any] else {
        fail("无法读取 Dock 配置")
    }
    return plist
}

func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSString { return value as String }
    return nil
}

func tileLabel(_ tile: [String: Any]) -> String? {
    guard let data = tile["tile-data"] as? [String: Any] else { return nil }
    return stringValue(data["file-label"])
}

func tilePath(_ tile: [String: Any]) -> String? {
    guard let data = tile["tile-data"] as? [String: Any],
          let file = data["file-data"] as? [String: Any],
          let raw = stringValue(file["_CFURLString"]) else { return nil }
    return raw
        .replacingOccurrences(of: "file://", with: "")
        .removingPercentEncoding?
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

func bookmarkData(for app: URL) -> Data? {
    try? app.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
}

func appTile(_ app: URL, label: String) -> [String: Any] {
    let encodedPath = app.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        ?? app.path
    var data: [String: Any] = [
        "dock-extra": false,
        "file-data": [
            "_CFURLString": "file://\(encodedPath)/",
            "_CFURLStringType": 15
        ],
        "file-label": label,
        "file-type": 41,
        "is-beta": false
    ]
    if let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
       let identifier = plist["CFBundleIdentifier"] as? String {
        data["bundle-identifier"] = identifier
    }
    if let bookmark = bookmarkData(for: app) { data["book"] = bookmark }
    return ["tile-data": data, "tile-type": "file-tile"]
}

func directoryTile(_ folder: URL, label: String) -> [String: Any] {
    let encodedPath = folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        ?? folder.path
    return [
        "tile-data": [
            "arrangement": 1,
            "displayas": 0,
            "dock-extra": false,
            "file-data": [
                "_CFURLString": "file://\(encodedPath)/",
                "_CFURLStringType": 15
            ],
            "file-label": label,
            "preferreditemsize": "-1",
            "showas": 2
        ],
        "tile-type": "directory-tile"
    ]
}

/// 将分组 tile 同步到 Dock plist，并在写入前自动保存可恢复的二进制备份。
func syncDock(_ config: Config, only: Set<String>? = nil, prune: Bool = true) {
    if ProcessInfo.processInfo.environment["DOCKGROUP_SKIP_DOCK"] == "1" {
        output("已跳过 Dock 写入（DOCKGROUP_SKIP_DOCK=1）")
        return
    }
    var plist = dockRead()
    let targets = config.groups.filter { only == nil ? $0.enabled : only!.contains($0.name) }
    let managed = Set(config.groups.map(\.name))
    let original = (plist["persistent-apps"] as? [[String: Any]]) ?? []
    let grouped = Set(targets.flatMap { group in
        appEntries(in: Paths.base.appendingPathComponent(group.name)).flatMap { entry in
            [entry.target.path, entry.target.resolvingSymlinksInPath().path]
        }
    })

    func keep(_ tile: [String: Any]) -> Bool {
        guard let label = tileLabel(tile), !managed.contains(label) else { return false }
        if !prune { return true }
        guard let path = tilePath(tile) else { return true }
        return !grouped.contains(path) && !grouped.contains(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    var left = original.filter(keep)
    var right = ((plist["persistent-others"] as? [[String: Any]]) ?? []).filter { tile in
        guard let label = tileLabel(tile), !managed.contains(label) else { return false }
        return !(tilePath(tile) ?? "").hasPrefix(Paths.base.path)
    }

    for group in targets {
        let tile: [String: Any]
        if group.placement == "right" {
            tile = directoryTile(Paths.base.appendingPathComponent(group.name), label: group.name)
            right.append(tile)
        } else {
            tile = appTile(Paths.apps.appendingPathComponent("\(group.name).app"), label: group.name)
            if let after = group.after,
               let index = left.firstIndex(where: { tilePath($0) == after }) {
                left.insert(tile, at: index + 1)
            } else {
                left.append(tile)
            }
        }
    }

    plist["persistent-apps"] = left
    plist["persistent-others"] = right
    do {
        try FileManager.default.createDirectory(at: Paths.backup, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try data.write(to: Paths.backup.appendingPathComponent("com.apple.dock-\(stamp).plist"), options: .atomic)
        _ = captured("/usr/bin/defaults", ["import", dockDomain, "-"], input: data)
        _ = run("/usr/bin/killall", ["Dock"])
        _ = run("/usr/bin/killall", ["Finder"])
    } catch {
        fail("写入 Dock 配置失败：\(error.localizedDescription)")
    }
}

func dockHas(_ name: String) -> Bool {
    let plist = dockRead()
    for key in ["persistent-apps", "persistent-others"] {
        if let tiles = plist[key] as? [[String: Any]], tiles.contains(where: { tileLabel($0) == name }) { return true }
    }
    return false
}

// ─── App bundle 构建 ───────────────────────────────────────

func executableURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

func engineResourceCopy(to resources: URL) {
    guard let source = Paths.sourceRoot else { fail("找不到引擎资源。请设置 DOCKGROUP_SOURCE_ROOT") }
    do {
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for relative in ["launcher/main.swift", "manager/main.swift"] {
            let sourceURL = source.appendingPathComponent(relative)
            let destination = resources.appendingPathComponent("engine-resources/\(relative)")
            if sourceURL.standardizedFileURL == destination.standardizedFileURL {
                continue
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
    } catch {
        fail("打包引擎资源失败：\(error.localizedDescription)")
    }
}

func compileLauncher() -> URL {
    guard let source = Paths.launcherSource else { fail("找不到 scripts/launcher/main.swift") }
    let output = Paths.cache.appendingPathComponent(".launcher.bin")
    try? FileManager.default.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
    let status = run(
        "/usr/bin/swiftc",
        ["-swift-version", "5", "-O", "-o", output.path, source.path, "-framework", "Cocoa"]
    )
    guard status == 0 else { fail("编译启动器失败") }
    return output
}

func pngToICNS(_ png: URL, _ icns: URL) {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
    do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let sizes = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024)
        ]
        for (name, size) in sizes {
            let output = temporary.appendingPathComponent("\(name).png")
            guard run(
                "/usr/bin/sips",
                ["-z", "\(size)", "\(size)", png.path, "--out", output.path]
            ) == 0 else {
                fail("缩放 App 图标失败")
            }
        }
        try FileManager.default.createDirectory(
            at: icns.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard run(
            "/usr/bin/iconutil",
            ["-c", "icns", temporary.path, "-o", icns.path]
        ) == 0 else {
            fail("生成 ICNS 失败")
        }
        try? FileManager.default.removeItem(at: temporary)
    } catch {
        fail("准备 ICNS 失败：\(error.localizedDescription)")
    }
}

/// 构建自包含的分组启动器：二进制、Swift 引擎、源资源和图标全部进入 bundle。
func buildLauncher(_ group: Group, style: String, material: String, layout: String) -> URL {
    let (mosaicURL, entries) = iconForGroup(group, style: style)
    let binary = compileLauncher()
    let app = Paths.apps.appendingPathComponent("\(group.name).app")
    let contents = app.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    let executable = contents.appendingPathComponent("MacOS/DockGroupLauncher")
    let info = contents.appendingPathComponent("Info.plist")
    do {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: executable.path) {
            try FileManager.default.removeItem(at: executable)
        }
        try FileManager.default.copyItem(at: binary, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        engineResourceCopy(to: resources)
        let engine = resources.appendingPathComponent("DockGroupEngine")
        if executableURL().standardizedFileURL != engine.standardizedFileURL {
            if FileManager.default.fileExists(atPath: engine.path) {
                try FileManager.default.removeItem(at: engine)
            }
            try FileManager.default.copyItem(at: executableURL(), to: engine)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        let icon = resources.appendingPathComponent("AppIcon.icns")
        pngToICNS(mosaicURL, icon)
        let plist: [String: Any] = [
            "CFBundleExecutable": "DockGroupLauncher",
            "CFBundleIdentifier": "local.dockgroup.app.\(abs(group.name.hashValue))",
            "CFBundleName": group.name,
            "CFBundleDisplayName": group.name,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "2.0.0",
            "CFBundleVersion": "2.0.0",
            "LSMinimumSystemVersion": "12.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "DockGroupName": group.name,
            "DockGroupMaterial": material,
            "DockGroupLayout": layout,
            "CFBundleDocumentTypes": [[
                "CFBundleTypeName": "Application",
                "CFBundleTypeRole": "Viewer",
                "LSHandlerRank": "Alternate",
                "LSItemContentTypes": ["com.apple.application", "com.apple.application-bundle"]
            ]]
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: info, options: .atomic)
        _ = run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        if FileManager.default.fileExists(atPath: launchServices) {
            _ = run(launchServices, ["-f", app.path])
        }
    } catch {
        fail("构建「\(group.name)」启动器失败：\(error.localizedDescription)")
    }
    output("  ✓ \(group.name) → \(app.path)（\(entries.count) 个 App）")
    return app
}

// ─── 命令 ──────────────────────────────────────────────────

func groupStyle(_ config: Config, _ group: Group) -> String {
    group.style ?? config.style
}

func groupMaterial(_ config: Config, _ group: Group) -> String {
    group.material ?? config.material
}

func groupLayout(_ config: Config, _ group: Group) -> String {
    group.layout ?? config.layout
}

func refresh(_ config: Config, names: Set<String>? = nil) {
    for group in config.groups where (names == nil || names!.contains(group.name)) {
        let folder = Paths.base.appendingPathComponent(group.name)
        guard FileManager.default.fileExists(atPath: folder.path) else { continue }
        if group.placement == "right" {
            _ = iconForGroup(group, style: groupStyle(config, group))
        } else {
            _ = buildLauncher(
                group,
                style: groupStyle(config, group),
                material: groupMaterial(config, group),
                layout: groupLayout(config, group)
            )
        }
    }
}

func commandNew(_ args: [String]) {
    var arguments = args
    let apply = arguments.contains("--apply")
    arguments.removeAll { $0 == "--apply" }
    guard arguments.count >= 2 else { fail("用法：dg new [--apply] <组名> \"App\" ...") }
    let name = arguments.removeFirst()
    var config = loadConfig()
    guard groupIndex(config, name: name) == nil else { fail("分组「\(name)」已存在") }
    let apps = arguments.compactMap { resolveApp($0) }
    guard apps.count == arguments.count else {
        let missing = arguments.filter { resolveApp($0) == nil }.joined(separator: "、")
        fail("有 App 无法解析：\(missing)")
    }
    let group = Group(name: name, apps: apps.map(\.path))
    let folder = Paths.base.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for app in apps { try? addAlias(from: app, to: folder) }
    config.groups.append(group)
    saveConfig(config)
    output("已添加分组「\(name)」（\(apps.count) 个 App）")
    if apply { commandApply([name]) }
}

func commandAdd(_ args: [String]) {
    guard args.count >= 2 else { fail("用法：dg add <组名> \"App\" ...") }
    let name = args[0]
    var config = loadConfig()
    guard let index = groupIndex(config, name: name) else { fail("没有分组「\(name)」") }
    let folder = Paths.base.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var added: [URL] = []
    for spec in args.dropFirst() {
        guard let app = resolveApp(spec) else { output("⚠ 找不到：\(spec)"); continue }
        let destination = folder.appendingPathComponent(app.deletingPathExtension().lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? addAlias(from: app, to: folder)
            added.append(app)
        }
    }
    guard !added.isEmpty else { output("没有新增任何 App"); return }
    config.groups[index].apps.append(contentsOf: added.map(\.path))
    saveConfig(config)
    refresh(config, names: [name])
    output("「\(name)」新增 \(added.count) 个 App")
}

func commandDelete(_ args: [String]) {
    guard args.count >= 2 else { fail("用法：dg del <组名> \"App\" ...") }
    let name = args[0]
    var config = loadConfig()
    guard let index = groupIndex(config, name: name) else { fail("没有分组「\(name)」") }
    let folder = Paths.base.appendingPathComponent(name)
    let entries = appEntries(in: folder)
    var removed: Set<String> = []
    for needle in args.dropFirst() {
        for entry in entries where entry.name.localizedCaseInsensitiveContains(needle) {
            let url = folder.appendingPathComponent(entry.name)
            if entry.alias {
                try? FileManager.default.removeItem(at: url)
                removed.insert(entry.name.lowercased())
            } else {
                output("⛔ 跳过真实 App：\(entry.name)")
            }
        }
    }
    config.groups[index].apps.removeAll { value in
        removed.contains(URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent.lowercased())
    }
    saveConfig(config)
    refresh(config, names: [name])
    output("「\(name)」移除 \(removed.count) 个 App")
}

/// 生成目标分组的 tile 并同步 Dock；DOCKGROUP_SKIP_DOCK 只用于离屏集成测试。
func commandApply(_ args: [String]) {
    var arguments = args
    let keepOriginals = arguments.contains("--keep-originals")
    arguments.removeAll { $0 == "--keep-originals" }
    let config = loadConfig()
    let names = arguments.isEmpty ? nil : Set(arguments)
    let targets = config.groups.filter { names == nil ? $0.enabled : names!.contains($0.name) }
    guard !targets.isEmpty else { fail("没有匹配的分组") }
    for group in targets {
        if group.placement == "right" {
            _ = iconForGroup(group, style: groupStyle(config, group))
        } else {
            _ = buildLauncher(
                group,
                style: groupStyle(config, group),
                material: groupMaterial(config, group),
                layout: groupLayout(config, group)
            )
        }
    }
    syncDock(config, only: names, prune: !keepOriginals)
}

func commandRebuild(_ args: [String]) {
    let config = loadConfig()
    refresh(config)
    if !config.groups.isEmpty,
       ProcessInfo.processInfo.environment["DOCKGROUP_SKIP_DOCK"] != "1" {
        _ = run("/usr/bin/killall", ["Dock"])
    }
}

func commandPreview(_ args: [String]) {
    let config = loadConfig()
    let names = args.isEmpty ? nil : Set(args)
    for group in config.groups where names == nil || names!.contains(group.name) {
        let result = iconForGroup(group, style: groupStyle(config, group), previewOnly: true)
        output("已合成 \(group.name)：\(result.0.path)")
    }
}

func commandStyle(_ args: [String]) {
    guard args.count >= 2 else { fail("用法：dg style <组名|--all> <材质>") }
    var config = loadConfig()
    let value = args[1]
    guard value == "default" || materials.contains(value) else { fail("没有「\(value)」这个面板材质") }
    if args[0] == "--all" {
        config.material = value == "default" ? "hud" : value
        for index in config.groups.indices { config.groups[index].material = nil }
    } else if let index = groupIndex(config, name: args[0]) {
        config.groups[index].material = value == "default" ? nil : value
    } else { fail("没有分组「\(args[0])」") }
    saveConfig(config)
    refresh(config)
}

func commandLayout(_ args: [String]) {
    guard args.count >= 2 else { fail("用法：dg layout <组名|--all> <模式>") }
    var config = loadConfig()
    let value = args[1]
    guard ["row", "auto", "dock", "dock-name", "dock-grid", "default"].contains(value) else {
        fail("没有「\(value)」这个布局")
    }
    if args[0] == "--all" {
        config.layout = value == "default" ? "row" : value
        for index in config.groups.indices { config.groups[index].layout = nil }
    } else if let index = groupIndex(config, name: args[0]) {
        config.groups[index].layout = value == "default" ? nil : value
    } else { fail("没有分组「\(args[0])」") }
    saveConfig(config)
    refresh(config)
}

func commandList() {
    let config = loadConfig()
    output("配置：\(Paths.config.path)\n落盘：\(Paths.base.path)\n")
    for group in config.groups {
        let entries = appEntries(in: Paths.base.appendingPathComponent(group.name))
        output(
            "  \(group.enabled ? "●" : "○") \(group.name)  "
                + "\(entries.count) 个 App  统一 Dock："
                + "\(dockHas(group.name) ? "✓" : "✗")"
        )
        for entry in entries { output("      \(entry.alias ? " " : "≠") \(entry.name) → \(entry.target.path)") }
    }
}

func commandOpen(_ args: [String]) {
    guard let name = args.first else { fail("请指定分组名") }
    _ = groupOrFail(loadConfig(), name: name)
    let folder = Paths.base.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    _ = run("/usr/bin/open", [folder.path])
}

func commandRemove(_ args: [String], clean: Bool) {
    guard !args.isEmpty else { fail("请指定分组名") }
    var plist = dockRead()
    for key in ["persistent-apps", "persistent-others"] {
        if let tiles = plist[key] as? [[String: Any]] {
            plist[key] = tiles.filter { !args.contains(tileLabel($0) ?? "") }
        }
    }
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        _ = captured("/usr/bin/defaults", ["import", dockDomain, "-"], input: data)
        _ = run("/usr/bin/killall", ["Dock"])
    } catch { fail("移除 Dock 分组失败：\(error.localizedDescription)") }
    if clean { for name in args { try? FileManager.default.removeItem(at: Paths.base.appendingPathComponent(name)) } }
}

func commandDoctor() {
    output("dockgroup \(engineVersion)\n")
    let tools = ["swiftc", "codesign", "iconutil", "sips", "osascript"]
    for tool in tools { output("  ✅  \(tool)") }
    let configPath = FileManager.default.fileExists(atPath: Paths.config.path)
        ? Paths.config.path
        : "（还没建）"
    output("\n  落盘目录：\(Paths.base.path)\n  配置文件：\(configPath)")
}

func buildManager() -> URL {
    guard let source = Paths.managerSource else { fail("找不到 scripts/manager/main.swift") }
    let app = Paths.apps.appendingPathComponent("DockGroup.app")
    let contents = app.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    let executable = contents.appendingPathComponent("MacOS/DockGroupManager")
    do {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let status = run(
            "/usr/bin/swiftc",
            [
                "-swift-version", "5", "-parse-as-library", "-O",
                "-o", executable.path, source.path,
                "-framework", "SwiftUI", "-framework", "Cocoa"
            ]
        )
        guard status == 0 else { fail("编译管理窗口失败") }
        engineResourceCopy(to: resources)
        let engine = resources.appendingPathComponent("DockGroupEngine")
        if executableURL().standardizedFileURL != engine.standardizedFileURL {
            if FileManager.default.fileExists(atPath: engine.path) {
                try FileManager.default.removeItem(at: engine)
            }
            try FileManager.default.copyItem(at: executableURL(), to: engine)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        let plist: [String: Any] = [
            "CFBundleExecutable": "DockGroupManager",
            "CFBundleIdentifier": "local.dockgroup.manager",
            "CFBundleName": "DockGroup",
            "CFBundleDisplayName": "DockGroup 设置",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": engineVersion,
            "CFBundleVersion": engineVersion,
            "LSMinimumSystemVersion": "12.0",
            "NSPrincipalClass": "NSApplication"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(
            to: contents.appendingPathComponent("Info.plist"),
            options: .atomic
        )
        _ = run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    } catch { fail("构建管理窗口失败：\(error.localizedDescription)") }
    return app
}

func commandGUI() {
    let app = buildManager()
    _ = run("/usr/bin/open", [app.path])
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.first == "--help" || args.first == "help" {
    output("""
    dg — macOS Dock 分组管理
      dg new 组名 App...
      dg add 组名 App...
      dg del 组名 App...
      dg apply [组名...]
      dg rebuild
      dg preview [组名...]
      dg style 组名 材质
      dg layout 组名 模式
      dg gui
      dg doctor
    """)
} else {
    switch args[0] {
    case "--version", "version": output("dockgroup \(engineVersion)")
    case "new": commandNew(Array(args.dropFirst()))
    case "add": commandAdd(Array(args.dropFirst()))
    case "del", "rm": commandDelete(Array(args.dropFirst()))
    case "apply": commandApply(Array(args.dropFirst()))
    case "rebuild": commandRebuild(Array(args.dropFirst()))
    case "preview": commandPreview(Array(args.dropFirst()))
    case "style": commandStyle(Array(args.dropFirst()))
    case "layout": commandLayout(Array(args.dropFirst()))
    case "list": commandList()
    case "open": commandOpen(Array(args.dropFirst()))
    case "remove": commandRemove(Array(args.dropFirst()), clean: false)
    case "clean": commandRemove(Array(args.dropFirst()), clean: true)
    case "doctor": commandDoctor()
    case "gui": commandGUI()
    default: fail("未知命令：\(args[0])")
    }
}
