// swift/Commands/Open.swift
//
// `dg open` —— 在 Finder 里打开分组文件夹。
// 对应 Python 的 cmd_open。

import Foundation

func cmdOpen(_ cfg: JSONObject, _ args: [String]) {
    if args.isEmpty {
        fatal("请指定分组名")
    }
    guard let g = cfg.group(named: args[0]) else {
        fatal("没有分组「\(args[0])」")
    }
    let folder = BASE.appendingPathComponent(g.name)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // 对照测试模式下不真开 Finder（Python 版同款开关）——
    // 否则每跑一轮对照测试就弹两个 Finder 窗口，而弹窗本身没有任何被测逻辑。
    if dockPlistOverride == nil {
        run("/usr/bin/open", [folder.path])
    }
    print("已打开 \(folder.path)")
    print("往里加 App：按住 ⌘ ⌥ 从「应用程序」拖进来 = 建别名（不会移动原 App）")
    print("加完跑一次：dockgroup.py rebuild")
}
