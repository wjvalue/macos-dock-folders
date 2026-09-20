// DockGroup Manager — 分组管理窗口
//
// 为什么单独做一个 App：命令行能做的事它都能做，但有三件事 CLI 天生做不好 ——
//   ① 看不见效果：7 种图标风格 × 13 种面板材质 × 4 种布局，命令行下每换一次都要
//      style → rebuild → 等 Dock 重启，才能看到一眼；这里改完立刻出图。
//   ② 记不住名字：加 App 得先把 App 名拼对（虽然引擎支持模糊匹配）。
//   ③ 状态分散：成员在分组文件夹、图标在 .cache、Dock 挂没挂要看 `dg list`。
// 这个窗口把三件事摊在一屏里。
//
// 它不是引擎的替代品：会改配置的动作（增删、应用、恢复）一律转发给
// scripts/dockgroup.py，和命令行共用同一套逻辑，两边不会各说各话。
// 只有「外观」三项是直接写 groups.json 的 —— 为了能即时预览，不至于每拖一下
// 滑块就重启一次 Dock。改完点「应用到 Dock」才真正落地。
//
// 构建方式沿用 launcher：swiftc 单文件 + 手写 Info.plist + ad-hoc 签名，
// 不引入 Xcode 工程，也不引入任何第三方依赖。

import SwiftUI
import Cocoa
import UniformTypeIdentifiers

// ─── 路径 ──────────────────────────────────────────────────

enum P {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// 与 dockgroup.py 的 BASE 保持同一口径（DOCKGROUP_HOME > ~/Dock Groups）。
    static let base: URL = {
        if let s = ProcessInfo.processInfo.environment["DOCKGROUP_HOME"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Dock Groups")
    }()

    static let config = base.appendingPathComponent("groups.json")
    static let cache = base.appendingPathComponent(".cache")

    /// 引擎脚本的绝对路径。GUI 进程的 PATH 只有 /usr/bin:/bin，
    /// 不能指望 dg 在 PATH 里 —— 构建时把绝对路径写进 Info.plist，
    /// 和 launcher 是同一套做法。环境变量优先，方便直接跑二进制调试。
    static let script: URL = {
        if let s = ProcessInfo.processInfo.environment["DOCKGROUP_SCRIPT"], !s.isEmpty {
            return URL(fileURLWithPath: s)
        }
        if let s = Bundle.main.object(forInfoDictionaryKey: "DockGroupScript") as? String,
           !s.isEmpty {
            return URL(fileURLWithPath: s)
        }
        return home.appendingPathComponent("Dock Groups/dockgroup.py")
    }()

    static func mosaic(_ group: String) -> URL {
        cache.appendingPathComponent("\(group).png")
    }
}

// ─── 选项表 ────────────────────────────────────────────────
// 和 dockgroup.py 的 STYLES / launcher 的 material(named:) 一一对应。
// 改任何一边都要同步另外两边。

let kStyles: [(String, String)] = [
    ("graphite",   "深灰石墨（默认）"),
    ("glass-dark", "黑玻璃"),
    ("dock",       "浅灰，与 Dock 同调"),
    ("dock-deep",  "浅灰，再深一档"),
    ("frost-light","半透明浅玻璃"),
    ("frost-blue", "冷调蓝玻璃"),
    ("paper",      "接近纯白"),
]

let kMaterials: [(String, String)] = [
    ("hud",              "深色玻璃（默认）"),
    ("menu",             "半透明灰玻璃"),
    ("sidebar",          "侧栏"),
    ("header",           "标题区"),
    ("popover",          "接近纯白"),
    ("titlebar",         "标题栏"),
    ("underWindow",      "窗口底部"),
    ("contentBackground","内容背景"),
    ("sheet",            "表单"),
    ("windowBackground", "窗口背景"),
    ("appearanceBased",  "跟随外观"),
    ("fullScreenUI",     "全屏 UI"),
    ("toolTip",          "提示气泡"),
]

let kLayouts: [(String, String)] = [
    ("row",       "长条（默认）"),
    ("auto",      "自适应网格"),
    ("dock",      "与 Dock 条等高"),
    ("dock-name", "与 Dock 等高 + 名字"),
]

// ─── 配置模型 ──────────────────────────────────────────────

/// 名字不能叫 Group —— SwiftUI 里有个同名的视图容器，会互相遮蔽。
struct AppGroup: Codable, Identifiable, Hashable {
    var name: String
    var enabled: Bool
    var placement: String?
    var after: String?
    var apps: [String]
    var style: String?
    var material: String?
    var layout: String?

    var id: String { name }

    init(name: String, enabled: Bool = false, apps: [String] = []) {
        self.name = name
        self.enabled = enabled
        self.apps = apps
    }

    enum CodingKeys: String, CodingKey {
        case name, enabled, placement, after, apps, style, material, layout
    }

    /// 手写解码：缺字段一律退回默认值。
    /// 合成的解码器遇到「带默认值的非可选属性 + 键缺失」会直接抛错，
    /// 而 groups.json 是用户和引擎共同维护的，不能假设字段齐全。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        placement = try? c.decode(String.self, forKey: .placement)
        after = try? c.decode(String.self, forKey: .after)
        apps = (try? c.decode([String].self, forKey: .apps)) ?? []
        style = try? c.decode(String.self, forKey: .style)
        material = try? c.decode(String.self, forKey: .material)
        layout = try? c.decode(String.self, forKey: .layout)
    }
}

struct Config: Codable {
    var style: String?
    var material: String?
    var layout: String?
    var groups: [AppGroup]

    init(style: String? = nil, material: String? = nil,
         layout: String? = nil, groups: [AppGroup] = []) {
        self.style = style
        self.material = material
        self.layout = layout
        self.groups = groups
    }

    enum CodingKeys: String, CodingKey { case style, material, layout, groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try? c.decode(String.self, forKey: .style)
        material = try? c.decode(String.self, forKey: .material)
        layout = try? c.decode(String.self, forKey: .layout)
        groups = (try? c.decode([AppGroup].self, forKey: .groups)) ?? []
    }
}

// ─── 配置序列化 ────────────────────────────────────────────
//
// 不用 JSONEncoder，自己拼。实测对比过（2026-09-20），两个原因：
//   ① 它的 prettyPrinted 输出是 `"key" : value`（冒号前多一个空格），而引擎那边
//      json.dump(indent=2) 是 `"key": value`；两边交替保存会让 groups.json
//      整个文件反复翻转，diff 里全是噪音。
//   ② 键顺序由哈希决定，每次都可能不同。
// groups.json 是要进版本库、要给人看的，格式稳定性比省这几行代码重要。

private func jsonQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 {
                out += String(format: "\\u%04x", u.value)
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

extension AppGroup {
    func jsonText(indent: String = "    ") -> String {
        let inner = indent + "  "
        var fields: [String] = []
        fields.append("\(inner)\"name\": \(jsonQuote(name))")
        fields.append("\(inner)\"enabled\": \(enabled)")
        // 分组级覆盖：没写就不输出，保持文件里「只有设置过的才有这个键」
        if let v = placement { fields.append("\(inner)\"placement\": \(jsonQuote(v))") }
        if let v = after { fields.append("\(inner)\"after\": \(jsonQuote(v))") }
        if apps.isEmpty {
            fields.append("\(inner)\"apps\": []")
        } else {
            let items = apps.map { inner + "  " + jsonQuote($0) }.joined(separator: ",\n")
            fields.append("\(inner)\"apps\": [\n\(items)\n\(inner)]")
        }
        if let v = style { fields.append("\(inner)\"style\": \(jsonQuote(v))") }
        if let v = material { fields.append("\(inner)\"material\": \(jsonQuote(v))") }
        if let v = layout { fields.append("\(inner)\"layout\": \(jsonQuote(v))") }
        return indent + "{\n" + fields.joined(separator: ",\n") + "\n" + indent + "}"
    }
}

extension Config {
    /// 顶层键顺序对齐引擎写出来的样子：style / groups / material / layout。
    func jsonText() -> String {
        var out = "{\n"
        out += "  \"style\": \(jsonQuote(style ?? "graphite")),\n"
        if groups.isEmpty {
            out += "  \"groups\": [],\n"
        } else {
            out += "  \"groups\": [\n"
                + groups.map { $0.jsonText() }.joined(separator: ",\n")
                + "\n  ],\n"
        }
        out += "  \"material\": \(jsonQuote(material ?? "hud")),\n"
        out += "  \"layout\": \(jsonQuote(layout ?? "row"))\n"
        out += "}\n"
        return out
    }
}

// ─── 模型 ──────────────────────────────────────────────────

@MainActor
final class AppModel: ObservableObject {
    @Published var groups: [AppGroup] = []
    @Published var selection: String?
    @Published var style = "graphite"
    @Published var material = "hud"
    @Published var layout = "row"

    /// 有没有 groups.json —— 没有就走首屏引导（跑一次 dg init）。
    @Published var installed = false
    @Published var running = false
    @Published var log = ""
    @Published var status = ""
    @Published var statusIsError = false
    /// 外观改动还没落到 Dock 上
    @Published var dirty = false
    /// 预览图换了就 +1，逼 SwiftUI 重建图片视图（NSImage 有缓存）。
    @Published var previewToken = 0
    @Published var showingNewSheet = false
    @Published var newName = ""

    init() { load() }

    // ── 读 ──

    func load() {
        guard let data = try? Data(contentsOf: P.config),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            installed = false
            return
        }
        installed = true
        groups = cfg.groups
        style = cfg.style ?? "graphite"
        material = cfg.material ?? "hud"
        layout = cfg.layout ?? "row"
        if selection == nil || !groups.contains(where: { $0.name == selection }) {
            selection = groups.first?.name
        }
    }

    var current: AppGroup? {
        guard let s = selection else { return nil }
        return groups.first { $0.name == s }
    }

    private func index(of name: String) -> Int? {
        groups.firstIndex { $0.name == name }
    }

    // ── 写 ──

    /// 落盘 groups.json。这是唯一由 GUI 直接写文件的地方 ——
    /// 其余会改配置的动作全部交给引擎，避免两边各写一份。
    func save() {
        let cfg = Config(style: style, material: material, layout: layout, groups: groups)
        do {
            try FileManager.default.createDirectory(at: P.base, withIntermediateDirectories: true)
            try cfg.jsonText().write(to: P.config, atomically: true, encoding: .utf8)
            installed = true
            dirty = true
        } catch {
            status = "保存配置失败：\(error.localizedDescription)"
            statusIsError = true
        }
    }

    func setStyle(_ v: String) {
        style = v
        preview()
    }

    func setMaterial(_ v: String) { material = v }

    func setLayout(_ v: String) { layout = v }

    // ── 跑引擎 ──

    /// 调 scripts/dockgroup.py。成功后会重新读一遍配置 ——
    /// 引擎可能会把 GUI 没碰过的字段（after、placement）也写一遍。
    func run(_ args: [String], reload: Bool = true) async {
        guard !running else { return }
        running = true
        statusIsError = false
        status = "正在执行 dg \(args.joined(separator: " "))…"
        let result = await Self.exec(args)
        log = result.text
        if result.code == 0 {
            status = "完成"
            statusIsError = false
        } else {
            status = "失败（退出码 \(result.code)）"
            statusIsError = true
        }
        running = false
        if reload && result.code == 0 {
            let keep = selection
            load()
            selection = keep
            previewToken += 1
        }
    }

    /// 子进程执行。PATH 显式补全：引擎要用 osascript / swiftc / codesign /
    /// iconutil / sips / mdfind，而 GUI 进程默认只有 /usr/bin:/bin。
    nonisolated static func exec(_ args: [String]) async -> (code: Int32, text: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = [P.script.path] + args
                p.currentDirectoryURL = P.script.deletingLastPathComponent()
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
                env["PYTHONUNBUFFERED"] = "1"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: (-1, "无法启动引擎：\(error.localizedDescription)\n检查 \(P.script.path)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus,
                                        String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    // ── 动作 ──

    func initConfig() {
        Task { await run(["init"]) }
    }

    func addApps(_ paths: [String], to name: String) {
        guard !paths.isEmpty else { return }
        Task { await run(["add", name] + paths) }
    }

    func removeApp(_ name: String, from group: String) {
        Task { await run(["del", group, name]) }
    }

    func applyToDock() {
        save()
        Task { await run(["apply"]) }
    }

    func removeFromDock(_ name: String) {
        Task { await run(["remove", name]) }
    }

    func openFolder(_ name: String) {
        Task { await run(["open", name], reload: false) }
    }

    func testPanel(_ name: String) {
        Task { await run(["test", name], reload: false) }
    }

    func restore() {
        Task { await run(["restore"]) }
    }

    /// 只刷新拼贴图标，不改 Dock。换风格后立刻出图靠它。
    func preview() {
        guard let g = current, !g.apps.isEmpty else { return }
        Task {
            await run(["preview", g.name], reload: false)
            previewToken += 1
        }
    }

    func createGroup() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        showingNewSheet = false
        guard !n.isEmpty, index(of: n) == nil else { return }
        groups.append(AppGroup(name: n, enabled: false, apps: []))
        selection = n
        save()
        status = "已建「\(n)」—— 拖 App 进来，再点「应用到 Dock」"
        statusIsError = false
    }

    func deleteGroup(_ name: String) {
        guard let i = index(of: name) else { return }
        groups.remove(at: i)
        if selection == name { selection = groups.first?.name }
        save()
        Task { await run(["clean", name]) }
    }

    // ── 拖放 ──

    func acceptDrop(_ providers: [NSItemProvider], into name: String) {
        for p in providers {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let d = item as? Data {
                    url = URL(dataRepresentation: d, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let s = item as? String {
                    url = URL(string: s)
                }
                guard let u = url, u.pathExtension.lowercased() == "app" else { return }
                Task { @MainActor in
                    AppModel.shared?.addApps([u.path], to: name)
                }
            }
        }
    }

    /// 让拖放回调（非主线程、拿不到环境对象）能找回模型。
    static weak var shared: AppModel?
}

// ─── 小组件 ────────────────────────────────────────────────

struct MosaicThumb: View {
    let group: String
    let size: CGFloat
    var token: Int = 0

    var body: some View {
        Group {
            if let img = NSImage(contentsOf: P.mosaic(group)) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .id("\(group)-\(token)")
    }
}

struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

func displayName(_ path: String) -> String {
    ((path as NSString).lastPathComponent as NSString).deletingPathExtension
}

// ─── 左栏：分组列表 ────────────────────────────────────────

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("分组").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.newName = ""
                    model.showingNewSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("新建分组")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach($model.groups) { $g in
                        GroupRow(group: $g, selected: model.selection == g.name)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = g.name }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 196)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }
}

struct GroupRow: View {
    @Binding var group: AppGroup
    let selected: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            MosaicThumb(group: group.name, size: 22, token: model.previewToken)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(group.enabled ? .primary : .secondary)
                Text(group.apps.isEmpty ? "空" : "\(group.apps.count) 个 App")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Toggle("", isOn: Binding(
                get: { group.enabled },
                set: { group.enabled = $0; model.save() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }
}

// ─── 中栏：成员 ────────────────────────────────────────────

struct MemberPane: View {
    @EnvironmentObject var model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let g = model.current {
                HStack(spacing: 8) {
                    Text(g.name).font(.system(size: 15, weight: .medium))
                    Text(g.enabled ? "已启用" : "未启用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("在 Finder 里打开") { model.openFolder(g.name) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ScrollView {
                    if g.apps.isEmpty {
                        VStack(spacing: 8) {
                            Text("这个分组还是空的")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text("把 Finder 里的 .app 拖到下边这块，或者直接拖进窗口")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 14)],
                                  alignment: .leading, spacing: 16) {
                            ForEach(g.apps, id: \.self) { path in
                                MemberTile(path: path) {
                                    model.removeApp(displayName(path), from: g.name)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 16)
                    }
                }

                dropZone
            } else {
                VStack(spacing: 10) {
                    Text(model.installed ? "左边选一个分组" : "还没有配置")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if !model.installed {
                        Button("扫描当前 Dock 生成配置") { model.initConfig() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 260)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            if let g = model.current {
                model.acceptDrop(providers, into: g.name)
            }
            return true
        }
    }

    private var dropZone: some View {
        HStack(spacing: 8) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            Text(targeted ? "松手加进这个分组" : "把 .app 拖到这里加入分组（只建别名，不动原件）")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }
}

struct MemberTile: View {
    let path: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                AppIcon(path: path, size: 46)
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white, Color.red)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -5)
                    .help("从分组里移除（只删别名）")
                }
            }
            Text(displayName(path))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .frame(width: 74)
        .onHover { hovering = $0 }
    }
}

// ─── 右栏：外观与预览 ──────────────────────────────────────

struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("外观")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            previewCard

            VStack(alignment: .leading, spacing: 12) {
                picker("图标风格", selection: Binding(
                    get: { model.style }, set: { model.setStyle($0) }), options: kStyles)
                picker("面板材质", selection: Binding(
                    get: { model.material }, set: { model.setMaterial($0) }), options: kMaterials)
                picker("面板排列", selection: Binding(
                    get: { model.layout }, set: { model.setLayout($0) }), options: kLayouts)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if model.dirty {
                Text("外观改动还没写进 Dock")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 6) {
                if let g = model.current, !g.apps.isEmpty {
                    Button("试弹一次面板") { model.testPanel(g.name) }
                        .controlSize(.small)
                }
                Button("从最近备份恢复 Dock") { model.restore() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 246)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private var previewCard: some View {
        VStack(spacing: 10) {
            if let g = model.current {
                MosaicThumb(group: g.name, size: 62, token: model.previewToken)
                Text("拼贴图标预览")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 62, height: 62)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(.horizontal, 16)
    }

    private func picker(_ title: String, selection: Binding<String>,
                        options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { opt in
                    Text("\(opt.0) · \(opt.1)").tag(opt.0)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

// ─── 底栏 ──────────────────────────────────────────────────

struct BottomBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            if showLog {
                ScrollView {
                    Text(model.log.isEmpty ? "（还没有输出）" : model.log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 132)
                .background(Color(nsColor: .textBackgroundColor))
            }

            HStack(spacing: 10) {
                if model.running {
                    ProgressView().controlSize(.small)
                }
                Text(model.status.isEmpty ? "就绪" : model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                    .lineLimit(1)

                Button(showLog ? "收起输出" : "看输出") { showLog.toggle() }
                    .controlSize(.small)

                Spacer()

                if let g = model.current {
                    Button("移除这个分组") { model.removeFromDock(g.name) }
                        .controlSize(.small)
                    Button("删除这个分组") { model.deleteGroup(g.name) }
                        .controlSize(.small)
                }
                Button("应用到 Dock") { model.applyToDock() }
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.groups.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// ─── 根视图 ────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar()
                Divider()
                MemberPane()
                Divider()
                Inspector()
            }
            Divider()
            BottomBar()
        }
        .frame(minWidth: 880, minHeight: 540)
        .environmentObject(model)
        .onAppear { AppModel.shared = model }
        .sheet(isPresented: $model.showingNewSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("新建分组").font(.system(size: 14, weight: .medium))
                TextField("分组名，比如「设计」", text: $model.newName)
                    .frame(width: 240)
                    .onSubmit { model.createGroup() }
                Text("建好后把 App 拖进来，再点「应用到 Dock」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { model.showingNewSheet = false }
                    Button("创建") { model.createGroup() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }
}

// ─── 自检 ──────────────────────────────────────────────────

extension AppModel {
    /// `--dump-config`：把 groups.json 读进来再原样写回去，打印结果。
    ///
    /// 为什么要留这个口子：打包成 .app 之后，save() 只能靠点按钮触发，
    /// 而这台机器上 osascript 模拟点击被 TCC 拦（-10004），自动化验证走不通。
    /// 有了它就能在命令行确认「GUI 的编解码在引擎那边仍然合法」——
    /// 这是两个进程之间唯一的契约，破了就是「窗口里改了、Dock 没反应」。
    static func dumpConfig() {
        guard let data = try? Data(contentsOf: P.config),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            FileHandle.standardError.write(
                "读不到或解析失败：\(P.config.path)\n".data(using: .utf8)!)
            return
        }
        print(cfg.jsonText(), terminator: "")
    }
}

// ─── 入口 ──────────────────────────────────────────────────

@main
struct DockGroupManagerApp: App {
    init() {
        if CommandLine.arguments.contains("--dump-config") {
            AppModel.dumpConfig()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("DockGroup 设置") {
            ContentView()
        }
    }
}
