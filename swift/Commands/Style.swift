// swift/Commands/Style.swift
//
// `dg style` —— 换面板底色（毛玻璃材质）。
// 对应 Python 的 cmd_style()。不带参数时是「看当前用了什么 + 列所有可选材质」。
//
// 分组级覆盖（groups[].material）优先级高于全局 —— 这是 2026-09-20 修过的坑，
// 「改了配置不生效」的三大成因之一。

import Foundation

func cmdStyle(_ cfg: JSONObject, _ args: [String]) {
    let rest = args.filter { !$0.hasPrefix("--") }
    let all = args.contains("--all")

    if rest.isEmpty {
        print("默认材质：\(cfg["material"]?.stringValue ?? DEFAULT_MATERIAL)")
        for g in cfg.groups {
            let own = g["material"]?.stringValue
            print("  \(pad(g.name, 12)) \(own ?? "（跟随默认）")")
        }
        print("\n可选材质：")
        for (k, desc) in MATERIALS {
            print("  \(pad(k, 18)) \(desc)")
        }
        print("\n用法：")
        print("  dg style 组名 hud       只改一个分组")
        print("  dg style --all hud      全部改成 hud")
        print("  dg style 组名 default   该分组退回全局默认")
        return
    }

    let mat: String
    if all {
        mat = rest[0]
    } else if rest.count >= 2 {
        mat = rest[1]
    } else {
        FileHandle.standardError.write("""
        用法：dg style <组名> <材质>   或   dg style --all <材质>
        跑 `dg style` 看不带参数的用法和材质清单

        """.data(using: .utf8)!)
        exit(1)
    }

    if mat != "default" && !MATERIALS.contains(where: { $0.0 == mat }) {
        FileHandle.standardError.write(
            ("没有「\(mat)」这个材质。可选：\n  " + MATERIALS.map(\.0).joined(separator: "\n  ") + "\n")
                .data(using: .utf8)!)
        exit(1)
    }

    var cfg = cfg
    let names: [String]
    if all {
        cfg["material"] = (mat == "default") ? nil : .string(mat)
        var gs = cfg.groups
        for i in gs.indices { gs[i]["material"] = nil }
        cfg.groups = gs
        try? saveConfig(cfg)
        names = cfg.groups.map(\.name)
        print("全部 \(names.count) 个分组 → \(mat)")
    } else {
        guard var g = cfg.group(named: rest[0]) else {
            FileHandle.standardError.write("没有分组「\(rest[0])」\n".data(using: .utf8)!)
            exit(1)
        }
        g["material"] = (mat == "default") ? nil : .string(mat)
        var gs = cfg.groups
        if let i = gs.firstIndex(where: { $0.name == g.name }) { gs[i] = g }
        cfg.groups = gs
        try? saveConfig(cfg)
        names = [g.name]
        print("「\(g.name)」→ \(mat)")
    }

    // 只有真的建过文件夹 / 启动器的分组才会被 refresh_groups 碰到
    let touched = refreshGroups(cfg, names: names, quiet: true)
    print("已更新：\(touched.isEmpty ? "无" : touched.joined(separator: ", "))（Dock 已重启）")
    if touched.isEmpty {
        print("提示：这些分组还没有生成图标，跑 `dg apply` 才会写进 Dock")
    }
}
