// swift/Core/AppFind.swift
//
// App 发现：把「名字 / 模糊词 / 完整路径」解析成 .app 路径。
// 对应 Python 的 resolve_app / _mdfind_app / APP_DIRS。
//
// 四级策略必须按同样的顺序走（对照测试依赖解析结果的确定性）：
//   ① 应用目录里精确匹配 stem（拿到的路径大小写正确）
//   ② LaunchServices 按名字找（JXA findapp 的直替 —— 同一个 NSWorkspace API）
//   ③ Spotlight 按显示名找 —— ② 只认英文名，中文名（「系统设置」）只有这里能命中
//   ④ 文件名模糊匹配兜底

import Cocoa

/// 与 scripts/dockgroup.py 第 1359 行的 APP_DIRS 顺序一致，别重排。
let APP_DIRS = ["/Applications", "/System/Applications",
                "/Applications/Utilities", "/System/Applications/Utilities"]

/// 用 Spotlight 按「显示名」找 App —— 这是匹配中文名的唯一可靠路子。
/// Spotlight 未建索引时 mdfind 返回非 0，直接当没找到。
private func mdfindApp(_ needle: String) -> URL? {
    let safe = needle
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "\"", with: "")
        .trimmingCharacters(in: .whitespaces)
    if safe.isEmpty { return nil }
    var dirs: [String] = []
    for d in APP_DIRS { dirs += ["-onlyin", d] }
    dirs += ["-onlyin", HOME.appendingPathComponent("Applications").path]
    // 先精确、再包含
    for q in ["kMDItemDisplayName == '\(safe)'",
              "kMDItemDisplayName == '*\(safe)*'"] {
        let r = run("/usr/bin/mdfind", dirs + [q])
        guard r.ok else { continue }
        for line in r.text.split(separator: "\n") {
            let p = URL(fileURLWithPath: String(line))
            if p.pathExtension == "app" && FileManager.default.fileExists(atPath: p.path) {
                return p
            }
        }
    }
    return nil
}

/// 把 'Google Chrome' / 'chrome' / 'Safari' / '系统设置' / 完整路径 解析成 App 路径。
func resolveApp(_ spec: String) -> URL? {
    let fm = FileManager.default
    let expanded = (spec as NSString).expandingTildeInPath
    if fm.fileExists(atPath: expanded) {
        return URL(fileURLWithPath: expanded)
    }

    let stem = spec.hasSuffix(".app") ? String(spec.dropLast(4)) : spec
    let low = stem.lowercased()
    var dirs = APP_DIRS
    dirs.append(HOME.appendingPathComponent("Applications").path)

    // ① 目录里精确匹配（拿到的 Path 大小写正确）
    //    Python 先 sorted(iterdir()) 再线性扫 —— 首个命中即返回，照抄这个顺序。
    for d in dirs {
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: d), includingPropertiesForKeys: nil) else { continue }
        let hit = items.filter { $0.pathExtension == "app" }
            .sorted { pyLess($0.path, $1.path) }
            .first { $0.deletingPathExtension().lastPathComponent.lowercased() == low }
        if let hit { return hit }
    }

    // ② LaunchServices 按名字找（对应 JXA findapp：NSWorkspace.fullPathForApplication，
    //    能覆盖 /System/Volumes/Preboot 里的 Safari 这类）
    if let found = NSWorkspace.shared.fullPath(forApplication: stem),
       fm.fileExists(atPath: found) {
        return URL(fileURLWithPath: found)
    }

    // ③ Spotlight 按显示名找
    if let hit = mdfindApp(stem) { return hit }

    // ④ 最后退化成文件名模糊匹配
    for d in dirs {
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: d), includingPropertiesForKeys: nil) else { continue }
        let hit = items.filter { $0.pathExtension == "app" }
            .sorted { pyLess($0.path, $1.path) }
            .first { $0.deletingPathExtension().lastPathComponent.lowercased().contains(low) }
        if let hit { return hit }
    }
    return nil
}
