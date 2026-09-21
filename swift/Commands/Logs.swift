// swift/Commands/Logs.swift
//
// `dg logs` —— 查看某个分组的运行日志：面板几何 + 点击事件轨迹。
// 对应 Python 的 cmd_logs。

import Foundation

/// 对齐 Python 的 `str.splitlines()`：按 \n 切分，但**末尾的分隔符不产生空行**
/// （"a\nb\n" → ["a","b"]）。Swift 的 split(omittingEmptySubsequences: false)
/// 会保留尾部空元素，直接用会多算一行、多打一个空行。
private func pySplitLines(_ s: String) -> [Substring] {
    var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines
}

func cmdLogs(_ cfg: JSONObject, _ args: [String]) {
    if args.isEmpty {
        fatal("用法：logs <组名>")
    }
    guard let g = cfg.group(named: args[0]) else {
        fatal("没有分组「\(args[0])」")
    }
    let name = g.name
    let state = CACHE.appendingPathComponent("\(name).launch.log")
    let events = CACHE.appendingPathComponent("\(name).events.log")

    if let data = try? Data(contentsOf: state) {
        print("— 面板几何（最近一次弹出）—")
        for line in pySplitLines(String(decoding: data, as: UTF8.self)) {
            print("  \(line)")
        }
        print()
    }
    if let data = try? Data(contentsOf: events) {
        // Python read_text(errors="replace") ≈ Swift 的 lossy 解码（坏字节 → U+FFFD）
        let lines = pySplitLines(String(decoding: data, as: UTF8.self))
        print("— 事件轨迹（最后 \(min(40, lines.count)) 行，共 \(lines.count) 行）—")
        for line in lines.suffix(40) {
            print("  \(line)")
        }
        print()
        print("  排查提示：")
        print("   · 只有 === launch，没有 mouseDown hit item  → 点击没送达视图（窗口层级/事件路由问题）")
        print("   · 有 mouseDown 但没有 launching            → 命中下标不对，目标路径有问题")
        print("   · 有 launching 但 openApplication 报错      → LaunchServices 拒绝启动")
        print("   · 出现 dismiss: click outside panel        → 被误判成点了面板外")
    } else {
        print("还没有事件日志：\(events.path)")
        print("去点一次 Dock 上的分组图标，再跑这个命令。")
    }
}
