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
    try? dockRemove(args)
    print("已从 Dock 移除：\(args.joined(separator: ", "))（文件夹保留）")
}

func cmdClean(_ cfg: JSONObject, _ args: [String]) {
    if args.isEmpty {
        fatal("请指定要清理的分组名")
    }
    let fm = FileManager.default
    try? dockRemove(args)
    for n in args {
        let f = BASE.appendingPathComponent(n)
        if fm.fileExists(atPath: f.path) {
            try? fm.removeItem(at: f)
        }
    }
    print("已从 Dock 移除并删除文件夹：\(args.joined(separator: ", "))")
}
