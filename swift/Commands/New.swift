// swift/Commands/New.swift
//
// `dg new` —— 新建分组。
// 对应 Python 的 cmd_new / interactive_new / prompt_group_name。

import Foundation

/// 问一个不重复的分组名。取消返回 nil。
func promptGroupName(_ cfg: JSONObject) -> String? {
    while true {
        let name = ask("新分组叫什么名字（如 AI / 工作 / 工具）")
        if name.isEmpty { return nil }
        if cfg.group(named: name) != nil {
            print("  「\(name)」已存在，换一个")
            continue
        }
        return name
    }
}

/// dg new（不带参数）→ 输组名 → 多选 App → 确认 → 问是否直接写进 Dock。
func interactiveNew(_ cfg: inout JSONObject) {
    requireTty("new")
    guard let name = promptGroupName(cfg) else { return }
    let paths = pickApps(cfg, nil)
    if paths.isEmpty {
        print("没有选择任何 App，分组未创建。")
        return
    }

    print("\n将创建分组「\(name)」，包含 \(paths.count) 个 App：")
    for p in paths {
        print("  · \(p.deletingPathExtension().lastPathComponent)")
    }
    if !confirm("确认创建？") {
        print("已取消")
        return
    }

    // 键顺序照抄 Python 的字面 dict：name / enabled / placement / apps
    let g = JSONObject([
        ("name", .string(name)),
        ("enabled", .bool(true)),
        ("placement", .string("left")),
        ("apps", .array(paths.map { .string($0.path) })),
    ])
    var gs = cfg.groups
    gs.append(g)
    cfg.groups = gs
    try? saveConfig(cfg)
    print("\n已添加分组「\(name)」")

    if confirm("直接写进 Dock（自动折叠原图标）？") {
        print()
        cmdApply(cfg, [name])
    } else {
        print("\n稍后写进 Dock：dg apply \(name)")
        print("先看图标长啥样：dg preview \(name)")
    }
}

func cmdNew(_ cfg0: JSONObject, _ args: [String]) {
    var cfg = cfg0
    let doApply = args.contains("--apply")
    let positional = args.filter { !$0.hasPrefix("--") }
    if positional.isEmpty {
        interactiveNew(&cfg)
        return
    }
    if positional.count < 2 {
        fatal("""
        用法：new <组名> "App 名或路径" ["更多 App"...]
        或直接敲 dg new 进入交互模式（输组名、敲数字选 App）
        一步到位：dg new --apply <组名> "App"...  建完直接写进 Dock
        """)
    }
    let gname = positional[0]
    let specs = Array(positional.dropFirst())
    if cfg.group(named: gname) != nil {
        fatal("分组「\(gname)」已存在，改配置或先 remove")
    }
    var paths: [URL] = []
    var bad: [String] = []
    for s in specs {
        if let p = resolveApp(s) {
            paths.append(p)
        } else {
            bad.append(s)
        }
    }
    if !bad.isEmpty {
        fatal("找不到这些 App：" + bad.joined(separator: "、"))
    }
    var gs = cfg.groups
    gs.append(JSONObject([
        ("name", .string(gname)),
        ("enabled", .bool(true)),
        ("placement", .string("left")),
        ("apps", .array(paths.map { .string($0.path) })),
    ]))
    cfg.groups = gs
    try? saveConfig(cfg)
    print("已添加分组「\(gname)」（\(paths.count) 个 App）：")
    for p in paths {
        print("  · \(p.path)")
    }
    if doApply {
        print()
        cmdApply(cfg, [gname])
    } else {
        let script = SCRIPT_DIR.appendingPathComponent("dockgroup.py").path
        print("\n下一步：\(script) preview \(gname)   → 看图标")
        print("       \(script) apply \(gname)     → 写进 Dock")
    }
}
