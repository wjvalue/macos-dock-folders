// swift/Commands/Del.swift
//
// `dg del`（别名 rm）—— 从分组里移除 App：删别名 → 同步配置 → 刷新图标 → 重启 Dock。
// 对应 Python 的 cmd_del。
//
// 只删别名文件；条目若是真实 App（目录）则拒绝删除并提示，避免误删用户
// 真正的应用程序。

import Foundation

func cmdDel(_ cfg0: JSONObject, _ args: [String]) {
    var cfg = cfg0
    let positional = args.filter { !$0.hasPrefix("--") }
    if positional.count < 2 {
        fatal("用法：del <组名> \"App 名\" [\"更多 App\"...]")
    }
    let gname = positional[0]
    let needles = Array(positional.dropFirst())
    guard cfg.group(named: gname) != nil else {
        fatal("没有分组「\(gname)」")
    }
    let g = cfg.group(named: gname)!
    let folder = BASE.appendingPathComponent(gname)
    var dirFlag: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &dirFlag),
          dirFlag.boolValue else {
        fatal("分组文件夹不存在：\(folder.path)")
    }

    let fm = FileManager.default
    let entries = folderEntries(folder)
    let inFolder = readFolderApps(folder)
    var removed: [URL] = []
    var missed: [String] = []
    var danger: [String] = []
    for n in needles {
        let low = n.lowercased()
        var hits = entries.filter {
            $0.deletingPathExtension().lastPathComponent.lowercased().contains(low)
        }
        if hits.isEmpty {
            // 再按 App 名解析一次 —— 覆盖中文输入（「系统设置」→ System Settings 别名）
            if let want = resolveApp(n) {
                hits = entries.filter { p in
                    inFolder.first(where: { $0.name == p.lastPathComponent })?.target.path == want.path
                }
            }
        }
        if hits.isEmpty {
            missed.append(n)
            continue
        }
        for p in hits {
            if removed.contains(where: { $0.path == p.path })
                || danger.contains(p.lastPathComponent) {
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue {
                danger.append(p.lastPathComponent)   // 真实 App（目录），不能删
                continue
            }
            try? fm.removeItem(at: p)                // 别名是文件，安全
            removed.append(p)
        }
    }

    if !missed.isEmpty {
        print("  ⚠ 分组里没有匹配：\(missed.joined(separator: "、"))")
    }
    if !danger.isEmpty {
        print("  ⛔ 这些是真实 App 而非别名，已跳过（要删请手动处理）：\(danger.joined(separator: "、"))")
    }
    if removed.isEmpty {
        fatal("没有移除任何 App")
    }

    for p in removed {
        print("  - \(p.deletingPathExtension().lastPathComponent)")
    }

    let gone = Set(removed.map {
        $0.deletingPathExtension().lastPathComponent.lowercased()
    })
    // Python 是 g["apps"] = [...]：就算原来没有 apps 键，也会写入一个空数组
    let kept = g.apps.filter {
        !gone.contains(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            .deletingPathExtension().lastPathComponent.lowercased())
    }
    var gs = cfg.groups
    if let i = gs.firstIndex(where: { $0.name == gname }) {
        gs[i]["apps"] = .array(kept.map { .string($0) })
        cfg.groups = gs
    }
    try? saveConfig(cfg)

    refreshGroups(cfg, names: [gname], quiet: true)
    let left = readFolderApps(folder).count
    print("\n「\(gname)」现在有 \(left) 个 App，图标已刷新。")
    if left == 0 {
        print("分组已空。加点东西进去（dg open \(gname)），或用 dg remove \(gname) 摘掉它。")
    }
}
