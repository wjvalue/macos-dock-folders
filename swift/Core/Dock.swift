// swift/Core/Dock.swift
//
// Dock 配置读取 + 分组文件夹扫描。
// 对应 Python 的 dock_read / dock_write / tile_label / tile_path / dock_has /
// read_folder_apps。

import Foundation

/// 同一次命令里反复读没意义，缓存住（Python 那边也一样）。
private var _dockCache: [String: Any]?

/// 写盘之后同步缓存，避免同一条命令里读到旧值。
func _dockCacheSet(_ pl: [String: Any]) { _dockCache = pl }

/// 读 Dock 配置。
///
/// 走 `defaults export` 起子进程 —— 和 Python 版**同一条路**，
/// 保证迁移期两边读到的东西完全一样（对照测试才有意义）。
/// 全 Swift 之后可以换成 `UserDefaults(suiteName: "com.apple.dock")`，
/// 但那要先验证 cfprefsd 的缓存语义一致，别顺手改。
///
/// 设了 `DOCKGROUP_DOCK_PLIST` 时改读那个文件（对照测试用，见 DockSync.swift）。
func dockRead(refresh: Bool = false) -> [String: Any] {
    if let c = _dockCache, !refresh { return c }

    let pl: [String: Any]
    if let override = dockPlistOverride {
        pl = readPlistDict(override) ?? [:]
    } else {
        let data = run("/usr/bin/defaults", ["export", DOCK_DOMAIN, "-"]).out
        pl = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any] ?? [:]
    }
    _dockCache = pl
    return pl
}

func tileLabel(_ tile: [String: Any]) -> String? {
    (tile["tile-data"] as? [String: Any])?["file-label"] as? String
}

func tilePath(_ tile: [String: Any]) -> String? {
    guard let td = tile["tile-data"] as? [String: Any],
          let fd = td["file-data"] as? [String: Any],
          let raw = fd["_CFURLString"] as? String else { return nil }
    // 对应 Python：urllib.parse.unquote(s).replace("file://", "").rstrip("/")
    var p = raw.removingPercentEncoding ?? raw
    p = p.replacingOccurrences(of: "file://", with: "")
    while p.hasSuffix("/") { p.removeLast() }
    return p
}

/// Dock 里有没有这个 label 的图标（两个区都找）。
func dockHas(_ label: String) -> Bool {
    let pl = dockRead()
    for key in ["persistent-apps", "persistent-others"] {
        if let tiles = pl[key] as? [[String: Any]],
           tiles.contains(where: { tileLabel($0) == label }) {
            return true
        }
    }
    return false
}

/// 当前 Dock 里所有 App 路径（**保序**去重 —— 顺序就是图标在 Dock 上的顺序）。
func dockAppList() -> [String] {
    var out: [String] = []
    let pl = dockRead()
    for key in ["persistent-apps", "persistent-others"] {
        guard let tiles = pl[key] as? [[String: Any]] else { continue }
        for t in tiles {
            guard let p = tilePath(t), p.hasSuffix(".app"), !out.contains(p) else { continue }
            out.append(p)
        }
    }
    return out
}

/// 解析 Finder 别名。
///
/// Python 那边靠 osascript 跑一段 JXA 去调 `URLByResolvingAliasFileAtURLOptionsError`
/// （选项 256 = WithoutUI）；Swift 直接调同名 API，少一层进程 ——
/// 这也正是「全 Swift 化会更一体化」的具体一处。
/// 语义一致：不是别名就返回原路径；解不出来返回 nil（不弹窗）。
func resolveAlias(_ url: URL) -> URL? {
    do {
        return try URL(resolvingAliasFileAt: url, options: [.withoutUI])
    } catch {
        return nil
    }
}

/// 扫描分组文件夹 → [(显示名, 真实路径, 是否真别名)]，按名称排序。
/// 对应 Python 的 `read_folder_apps()`。
func readFolderApps(_ folder: URL) -> [(name: String, target: URL, isAlias: Bool)] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: folder,
                                                    includingPropertiesForKeys: nil) else {
        return []
    }
    let visible = entries.filter {
        $0.lastPathComponent != ICON_ENTRY && !$0.lastPathComponent.hasPrefix(".")
    }
    // 排序键用 lowercased()（和 Python 一致），再拿原名兜底 ——
    // Swift 的 sort **不保证稳定**，不给 tiebreaker 的话「忽略大小写后同名」
    // 的条目顺序会和 Python 对不上。
    let sorted = visible.sorted {
        let a = $0.lastPathComponent.lowercased()
        let b = $1.lastPathComponent.lowercased()
        return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
    }

    var out: [(name: String, target: URL, isAlias: Bool)] = []
    for p in sorted {
        // 解不出目标、或目标已不存在 → 丢弃（Python 也是这么做的）
        guard let target = resolveAlias(p), fm.fileExists(atPath: target.path) else { continue }
        out.append((p.lastPathComponent, target, target.path != p.path))
    }
    return out
}
