// swift/Commands/Rebuild.swift
//
// `dg rebuild` —— 只重建图标与 App，不动 Dock 里的位置。
// 对应 Python 的 cmd_rebuild / refresh_groups。

import Foundation

/// 重建指定分组的图标与启动器，然后重启 Dock。`names` 为 nil 表示全部。
///
/// `add` / `del` / `rebuild` 都走这里，保证「改完即生效」。
/// 注意它**会 killall Dock** —— 从 WorkBuddy 沙箱里直接跑会把当前命令连带打死
/// （exit 137、零输出，看起来像没执行）。要么带沙箱豁免，要么丢后台落日志。
@discardableResult
func refreshGroups(_ cfg: JSONObject, names: [String]? = nil, quiet: Bool = false) -> [String] {
    var touched: [String] = []
    var skipped: [String] = []

    for g in cfg.groups {
        if let ns = names, !ns.contains(g.name) { continue }
        let folder = BASE.appendingPathComponent(g.name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else { continue }
        do {
            // seed=false：刷新只改图标，绝不改变成员 ——
            // 否则刚被 del 删掉的成员会被配置里的旧列表重新播种回来
            let style = groupStyle(cfg, g)   // 分组覆盖优先于全局，与 apply 同一套规则
            if g.placement == "right" {
                try buildGroup(g, style: style, seed: false)
            } else {
                try buildLauncherApp(g, style: style, material: groupMaterial(cfg, g),
                                     layout: groupLayout(cfg, g), seed: false)
            }
            touched.append(g.name)
        } catch let e as DgError {
            skipped.append(e.message)   // 单个分组失败不影响其它分组
        } catch {
            skipped.append("\(error)")
        }
    }

    if !touched.isEmpty {
        try? FileManager.default.createDirectory(at: CACHE, withIntermediateDirectories: true)
        try? String(Date().timeIntervalSince1970).write(
            to: CACHE.appendingPathComponent(".last-build"), atomically: true, encoding: .utf8)
        // 先杀启动器再重启 Dock：顺序反过来的话，重启完 Dock 又有一瞬间可能被点到，
        // 那时旧进程还在，就会用旧布局再画一次面板。
        killLaunchers()
        if dockPlistOverride == nil {       // 对照测试模式下不碰真实 Dock
            run("/usr/bin/killall", ["Dock"])
            run("/usr/bin/killall", ["Finder"])
        }
    }
    if !quiet {
        for s in skipped { print("  跳过：\(s)") }
    }
    return touched
}

func cmdRebuild(_ cfg: JSONObject, _ args: [String]) {
    let quiet = args.contains("--quiet")

    // 防监听自触发死循环：监听器看到文件夹变化会调 rebuild，
    // 而 rebuild 自己又会动文件夹。4 秒内的重复调用直接忽略。
    let guardFile = CACHE.appendingPathComponent(".last-build")
    if quiet,
       let attrs = try? FileManager.default.attributesOfItem(atPath: guardFile.path),
       let d = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince1970 - d.timeIntervalSince1970 < 4 {
        return
    }

    let touched = refreshGroups(cfg, quiet: quiet)
    if !quiet {
        print("已刷新：\(touched.isEmpty ? "无" : touched.joined(separator: ", "))（Dock 已重启）")
    }
}
