// swift/Commands/Remove.swift
//
// `dg remove` / `dg clean` —— 从 Dock 摘掉分组（clean 连文件夹一起删）。
// 对应 Python 的 cmd_remove / cmd_clean / dock_remove（dockRemove 已在
// DockSync.swift 里随 dock_sync 一轮搬完）。

import Foundation

func cmdRemove(_ cfg: JSONObject, _ args: [String]) {
    if args.isEmpty {
        fatal("请指定要移除的分组名")
    }
    for n in args {
        if let why = groupNameProblem(n) { fatal("「\(n)」：\(why)") }
    }
    // ⚠️ 不能 try?：写失败（权限、磁盘满）静默吞掉还打印「已移除」，是假成功。
    do {
        try dockRemove(args)
    } catch let e as DgError {
        fatal(e.message)
    } catch {
        fatal("从 Dock 移除失败：\(error)")
    }
    print("已从 Dock 移除：\(args.joined(separator: ", "))（文件夹保留）")
}

func cmdClean(_ cfg: JSONObject, _ args: [String]) {
    if args.isEmpty {
        fatal("请指定要清理的分组名")
    }
    for n in args {
        if let why = groupNameProblem(n) { fatal("「\(n)」：\(why)") }
    }
    let fm = FileManager.default
    do {
        try dockRemove(args)
    } catch let e as DgError {
        fatal(e.message)
    } catch {
        fatal("从 Dock 移除失败：\(error)")
    }
    for n in args {
        // 围栏（名字校验之外的第二道保险）：解析后必须是 BASE 的直接子路径。
        // 删除是这里最不能出错的一步，宁可多防一层。
        let f = BASE.appendingPathComponent(n).standardizedFileURL
        guard f.deletingLastPathComponent().standardizedFileURL.path
                  == BASE.standardizedFileURL.path else {
            fatal("拒绝删除「\(n)」：解析后的路径不在 \(BASE.path) 里")
        }
        if fm.fileExists(atPath: f.path) {
            do {
                try fm.removeItem(at: f)
            } catch {
                fatal("删除文件夹失败：\(f.path)\n\(error.localizedDescription)")
            }
        }
    }
    print("已从 Dock 移除并删除文件夹：\(args.joined(separator: ", "))")
}
