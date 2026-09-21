// swift/Commands/Apply.swift
//
// `dg apply` —— 生成 App 并写进 Dock。
// 对应 Python 的 cmd_apply()。这是整个工具的主命令：一次把「建图标 → 建 .app →
// 改 Dock 配置」全做完。
//
// 输出要和 Python 版逐字符一致（对照测试盯着的就是这个）。

import Foundation

func cmdApply(_ cfg: JSONObject, _ args: [String]) {
    let keep = args.contains("--keep-originals")
    let positional = args.filter { !$0.hasPrefix("--") }
    let only: Set<String>? = positional.isEmpty ? nil : Set(positional)

    let targets = syncTargets(cfg, only: only)
    if targets.isEmpty {
        FileHandle.standardError.write("没有匹配的分组\n".data(using: .utf8)!)
        exit(1)
    }

    let style = cfg.style
    let before = (dockRead()["persistent-apps"] as? [[String: Any]] ?? []).count

    for g in targets {
        do {
            let dest: URL
            let okCount: Int
            let missing: [String]
            if g.placement == "right" {
                let r = try buildGroup(g, style: style)
                dest = r.folder; okCount = r.ok.count; missing = r.missing
            } else {
                let r = try buildLauncherApp(g, style: style,
                                             material: groupMaterial(cfg, g),
                                             layout: groupLayout(cfg, g))
                dest = r.app; okCount = r.ok.count; missing = r.missing
            }
            print("  ✓ \(g.name) → \(dest.path)（\(okCount) 个 App）")
            if !missing.isEmpty {
                print("       ⚠ 跳过 \(missing.count) 个不存在的 App")
            }
        } catch let e as DgError {
            // Python 那边 build_group / build_launcher_app 失败是 sys.exit ——
            // 整个 apply 直接停，不做「跳过继续」。照抄。
            FileHandle.standardError.write("\(e.message)\n".data(using: .utf8)!)
            exit(1)
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // ⚠️ 注意传的是 only: nil 而不是上面那个 only —— Python 就是这么写的
    // （cmd_apply 里是 `dock_sync(cfg, only=None, prune=not keep)`）。
    // 看着像笔误，但这是原版行为：sync 阶段一律处理**所有** enabled 分组，
    // 免得只 apply 一个分组时把别的分组的图标从 Dock 上漏掉。
    do {
        try dockSync(cfg, only: nil, prune: !keep)
    } catch let e as DgError {
        FileHandle.standardError.write("\(e.message)\n".data(using: .utf8)!)
        exit(1)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }

    let after = (dockRead()["persistent-apps"] as? [[String: Any]] ?? []).count
    print("\nDock 左侧 App 图标：\(before) → \(after)")
    if killLaunchers() {
        print("  已结束正在运行的启动器 —— 下次点开面板才会用上新布局")
    }
    for g in targets {
        let pos: String
        if let anchor = g["after"]?.stringValue, !anchor.isEmpty {
            let stem = URL(fileURLWithPath: anchor).deletingPathExtension().lastPathComponent
            pos = "左侧 App 区（\(stem) 之后）"
        } else if g.placement == "right" {
            pos = "分隔线右侧"
        } else {
            pos = "左侧 App 区末尾"
        }
        print("  分组「\(g.name)」位置：\(pos)")
    }
    // 这句和 Python 版**逐字相同**（含 dockgroup.py 这个名字）：
    // 迁移期两边输出要能直接 diff，等切换之后再改成 dg restore。
    print("备份在 ~/Dock Groups/.backup/，出错用 dockgroup.py restore 回滚")
}
