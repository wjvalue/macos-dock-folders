// swift/Commands/Layout.swift
//
// `dg layout` —— 换弹出面板的网格布局。
// 对应 Python 的 cmd_layout()。不带参数时是「看当前用了什么 + 每个分组会排成几宫格」。
//
// 和 cmd_style 是同一套「分组覆盖全局」的规则，连分支结构都刻意保持一致 ——
// 这两个命令将来应该合并成一份实现，但现在先照抄原版的形状，别在迁移期顺手重构。

import Foundation

func cmdLayout(_ cfg: JSONObject, _ args: [String]) {
    let rest = args.filter { !$0.hasPrefix("--") }
    let all = args.contains("--all")

    if rest.isEmpty {
        print("默认布局：\(cfg["layout"]?.stringValue ?? DEFAULT_LAYOUT)")
        for g in cfg.groups {
            let own = g["layout"]?.stringValue ?? "（跟随默认）"
            guard let n = groupAppCount(g) else {
                print("  \(pad(g.name, 12)) \(pad(own, 14)) 文件夹不存在")
                continue
            }
            let mode = groupLayout(cfg, g)
            let (cols, rows) = layoutGrid(mode, n)
            let size = panelSize(mode, n)
            // 对应 Python 的 `{n:>2}`：数字右对齐宽度 2
            print("  \(pad(g.name, 12)) \(pad(own, 14)) \(String(format: "%2d", n)) 个 App → \(cols)×\(rows)  \(size.w)×\(size.h)")
        }
        print("\n可选布局：")
        for (k, desc) in LAYOUTS {
            print("  \(pad(k, 10)) \(desc)")
        }
        print("\n用法：")
        print("  dg layout 组名 row        只让这个分组保持原来的长条样式")
        print("  dg layout 组名 dock       改成和 Dock 条等高（图标撑满、不显示名字）")
        print("  dg layout 组名 dock-name  和 Dock 条等高 + 保留名字（比 Dock 高 8pt）")
        print("  dg layout 组名 dock-grid  和 Dock 条两倍等高 · 无字网格（2×2 = 144×144）")
        print("  dg layout --all auto      全部改成自适应网格")
        print("  dg layout 组名 default    该分组退回全局默认")
        return
    }

    let mode: String
    if all {
        mode = rest[0]
    } else if rest.count >= 2 {
        mode = rest[1]
    } else {
        FileHandle.standardError.write("""
        用法：dg layout <组名> <模式>   或   dg layout --all <模式>
        跑 `dg layout` 看不带参数的用法和布局清单

        """.data(using: .utf8)!)
        exit(1)
    }

    if mode != "default" && !LAYOUTS.contains(where: { $0.0 == mode }) {
        FileHandle.standardError.write(
            ("没有「\(mode)」这个布局。可选：\n  " + LAYOUTS.map(\.0).joined(separator: "\n  ") + "\n")
                .data(using: .utf8)!)
        exit(1)
    }

    var cfg = cfg
    let names: [String]
    if all {
        cfg["layout"] = (mode == "default") ? nil : .string(mode)
        var gs = cfg.groups
        for i in gs.indices { gs[i]["layout"] = nil }
        cfg.groups = gs
        try? saveConfig(cfg)
        names = cfg.groups.map(\.name)
        print("全部 \(names.count) 个分组 → \(mode)")
    } else {
        guard var g = cfg.group(named: rest[0]) else {
            FileHandle.standardError.write("没有分组「\(rest[0])」\n".data(using: .utf8)!)
            exit(1)
        }
        g["layout"] = (mode == "default") ? nil : .string(mode)
        var gs = cfg.groups
        if let i = gs.firstIndex(where: { $0.name == g.name }) { gs[i] = g }
        cfg.groups = gs
        try? saveConfig(cfg)
        names = [g.name]
        print("「\(g.name)」→ \(mode)")
    }

    let touched = refreshGroups(cfg, names: names, quiet: true)
    print("已更新：\(touched.isEmpty ? "无" : touched.joined(separator: ", "))（Dock 已重启）")
    if touched.isEmpty {
        print("提示：这些分组还没有生成图标，跑 `dg apply` 才会写进 Dock")
    }
}
