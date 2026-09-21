// swift/Commands/Add.swift
//
// `dg add` —— 往已有分组里加 App：建别名 → 同步配置 → 刷新图标 → 重启 Dock。
// 对应 Python 的 cmd_add / _add_apps / interactive_add。
//
// ⚠️ _add_apps 的「todo 为空就廉价返回」分支必须保住：拖放场景下系统可能把
// 同一个 kAEOpenDocuments 送两次（实测隔 7 秒又来一次），第二次必须是
// 廉价空操作，否则会白白重启一次 Dock。

import Foundation

/// 把已解析好的 App 路径加进分组：建别名 → 同步配置 → 刷新图标 → 重启 Dock。
/// cmd_add 与交互模式共用这条，保证两条路的行为完全一致。返回实际新增的个数。
@discardableResult
func addApps(_ cfg: inout JSONObject, _ g: JSONObject, _ paths: [URL]) -> Int {
    let gname = g.name
    let folder = BASE.appendingPathComponent(gname)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fm = FileManager.default

    var todo: [URL] = []
    var dup: [String] = []
    for p in paths {
        let stem = p.deletingPathExtension().lastPathComponent
        if fm.fileExists(atPath: folder.appendingPathComponent(stem).path) {
            dup.append(stem)
        } else if !todo.contains(where: { $0.path == p.path }) {
            todo.append(p)
        }
    }
    if !dup.isEmpty {
        print("  · 已在分组里，跳过：\(dup.joined(separator: "、"))")
    }
    if todo.isEmpty {
        // 没有任何新增就直接返回，不做刷新、不重启 Dock。
        return 0
    }

    makeAliases(in: folder, todo)
    for p in todo {
        print("  + \(p.deletingPathExtension().lastPathComponent)")
    }

    // 配置里的 apps 列表同步，保证 groups.json 与文件夹一致。
    // 注意 setdefault 语义：键不存在时也要把 "apps": [] 写进 JSON（Python 亦然）。
    var apps = g["apps"]?.stringArray ?? []
    let known = Set((g["apps"]?.stringArray ?? []).map { ($0 as NSString).expandingTildeInPath })
    for p in todo where !known.contains(p.path) {
        apps.append(p.path)
    }
    var gs = cfg.groups
    if let i = gs.firstIndex(where: { $0.name == gname }) {
        gs[i]["apps"] = .array(apps.map { .string($0) })
        cfg.groups = gs
    }
    try? saveConfig(cfg)

    refreshGroups(cfg, names: [gname], quiet: true)
    return todo.count
}

/// dg add（不带参数）→ 选分组 → 多选 App → 确认 → 自动刷新。
func interactiveAdd(_ cfg: inout JSONObject) {
    requireTty("add")
    if cfg.groups.isEmpty {
        print("还没有分组。先建一个：dg new")
        return
    }
    guard let g = pickGroup(cfg, "把 App 加到哪个分组") else { return }
    let paths = pickApps(cfg, g.name)
    if paths.isEmpty {
        print("没有选择任何 App。")
        return
    }

    print("\n将把以下 App 加进「\(g.name)」：")
    for p in paths {
        print("  · \(p.deletingPathExtension().lastPathComponent)")
    }
    if !confirm("确认？") {
        print("已取消")
        return
    }

    let added = addApps(&cfg, g, paths)
    let total = readFolderApps(BASE.appendingPathComponent(g.name)).count
    if added > 0 {
        print("\n「\(g.name)」现在有 \(total) 个 App，图标已刷新。")
    } else {
        print("\n没有新增 App（「\(g.name)」已有 \(total) 个）。")
    }
    if !dockHas(g.name) {
        if confirm("「\(g.name)」还没在 Dock 里，现在写进去？") {
            print()
            cmdApply(cfg, [g.name])
        }
    }
}

func cmdAdd(_ cfg0: JSONObject, _ args: [String]) {
    var cfg = cfg0
    let positional = args.filter { !$0.hasPrefix("--") }
    if positional.isEmpty {
        interactiveAdd(&cfg)
        return
    }
    if positional.count < 2 {
        fatal("""
        用法：add <组名> "App 名或路径" ["更多 App"...]
        或直接敲 dg add 进入交互模式（列分组、列 App，敲数字选）
        """)
    }
    let gname = positional[0]
    let specs = Array(positional.dropFirst())
    guard cfg.group(named: gname) != nil else {
        fatal("没有分组「\(gname)」。新建一个：dg new \(gname) "
              + specs.map { "\"\($0)\"" }.joined(separator: " "))
    }
    let g = cfg.group(named: gname)!

    var todo: [URL] = []
    var bad: [String] = []
    for s in specs {
        if let p = resolveApp(s) {
            if !todo.contains(where: { $0.path == p.path }) { todo.append(p) }
        } else {
            bad.append(s)
        }
    }
    if !bad.isEmpty {
        print("  ⚠ 找不到：\(bad.joined(separator: "、"))")
    }
    if todo.isEmpty {
        fatal("没有新增任何 App")
    }

    let added = addApps(&cfg, g, todo)
    let total = readFolderApps(BASE.appendingPathComponent(gname)).count
    if added > 0 {
        print("\n「\(gname)」现在有 \(total) 个 App，图标已刷新。")
    } else {
        print("\n没有新增 App（「\(gname)」已有 \(total) 个）。")
    }
    if !dockHas(gname) {
        print("它还没在 Dock 里 —— 跑 `dg apply \(gname)` 加进去。")
    }
}
