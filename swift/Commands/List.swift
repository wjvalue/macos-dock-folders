// swift/Commands/List.swift
//
// `dg list` —— 列出配置里的分组。
// 对应 Python 的 cmd_list()，输出要**逐字符一致**。

import Foundation

func cmdList(_ args: [String]) {
    let cfg = loadConfig()

    print("配置：\(CONFIG_PATH.path)")
    print("落盘：\(BASE.path)")
    print()

    for g in cfg.groups {
        var apps = readFolderApps(BASE.appendingPathComponent(g.name))
        var source = "文件夹"

        // 文件夹为空时退回配置里记的路径（文件夹优先，它是唯一事实来源）
        if apps.isEmpty {
            source = "配置"
            apps = g.apps.map { raw in
                let u = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                return (name: u.deletingPathExtension().lastPathComponent,
                        target: u, isAlias: false)
            }
        }

        let flag = g.enabled ? "●" : "○"
        let dock = dockHas(g.name) ? "Dock✓" : "Dock✗"
        print("  \(flag) \(pad(g.name, 10)) \(apps.count) 个 App（来自\(source)）   \(dock)")

        for a in apps {
            // ! 路径不存在；≠ 是真实 App 而不是别名（建议换回别名）
            let exists = FileManager.default.fileExists(atPath: a.target.path)
            let mark = !exists ? "!" : (a.isAlias ? " " : "≠")
            print("      \(mark) \(pad(a.name, 16)) → \(a.target.path)")
        }
    }

    print()
    print("  ● 启用   ○ 停用   ≠ 是真实 App 而非别名（建议换回别名）")
}
