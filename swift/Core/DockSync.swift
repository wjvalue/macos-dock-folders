// swift/Core/DockSync.swift
//
// Dock 配置的写入与同步。对应 Python 的 dock_write / make_tile / tile_for /
// _targets / _insert_after / dock_sync / dock_remove。
//
// 这是整个工具里**唯一会改动用户 Dock** 的地方，也是最该小心的一段：
// 写之前一定留备份（`~/Dock Groups/.backup/`），出问题能 restore 回滚。

import Foundation

// ─────────────────────────────────────────────── 测试用的 Dock 替身

/// 设了 `DOCKGROUP_DOCK_PLIST` 之后，读写 Dock 配置改成读写指定文件，
/// **不碰真实 Dock、不 killall、不留备份**。
///
/// 为什么必须有这个开关：对照测试要拿同一份输入同时跑两套实现、比对产物。
/// 真跑一遍的话，两套实现会先后把用户的 Dock 真改掉（而且是改两次），
/// 还会 killall Dock —— 从沙箱里跑会把当前命令连带打死（exit 137、零输出）。
///
/// Python 版有同款开关，两边行为必须一致，否则对照测试比的就不是同一件事了。
var dockPlistOverride: URL? {
    guard let p = ProcessInfo.processInfo.environment["DOCKGROUP_DOCK_PLIST"], !p.isEmpty
    else { return nil }
    return URL(fileURLWithPath: p)
}

// ─────────────────────────────────────────────── 写 Dock

/// 写 Dock 配置：备份 → 导入 → 重启 Dock / Finder。
func dockWrite(_ pl: [String: Any]) throws {
    let data = try plistData(pl)

    if let override = dockPlistOverride {
        try data.write(to: override)
        _dockCacheSet(pl)
        return
    }

    try FileManager.default.createDirectory(at: BACKUP, withIntermediateDirectories: true)
    let stamp = DateFormatter.pythonStamp.string(from: Date())
    try data.write(to: BACKUP.appendingPathComponent("com.apple.dock-\(stamp).plist"))

    let r = run("/usr/bin/defaults", ["import", DOCK_DOMAIN, "-"], input: data)
    guard r.ok else {
        throw DgError("导入 Dock 配置失败：\(r.errText.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    _dockCacheSet(pl)
    run("/usr/bin/killall", ["Dock"])
    run("/usr/bin/killall", ["Finder"])
}

private extension DateFormatter {
    /// `datetime.now():%Y%m%d-%H%M%S` —— 备份文件名的格式。
    /// 锁 en_US_POSIX：否则某些区域设置下会输出佛历 / 和历年份，文件名就没法看了。
    static let pythonStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

// ─────────────────────────────────────────────── tile 构造

/// 右侧「文件夹 Stack」用的 directory-tile。
func makeDirectoryTile(_ folder: URL, label: String) -> [String: Any] {
    let escaped = folder.path.addingPercentEncoding(withAllowedCharacters: pyQuoteSafe)
        ?? folder.path
    return [
        "tile-data": [
            "arrangement": 1,        // 按名称排序
            "displayas": 0,          // 显示为文件夹 → 才会用自定义图标
            "dock-extra": false,
            "file-data": [
                "_CFURLString": "file://\(escaped)/",
                "_CFURLStringType": 15,
            ],
            "file-label": label,
            "preferreditemsize": "-1",
            "showas": 2,             // 网格视图
        ],
        "tile-type": "directory-tile",
    ]
}

/// 分组该用哪种 tile：右侧 = 文件夹 Stack，左侧 = 启动器 App。
func tileFor(_ g: JSONObject) -> [String: Any] {
    if g.placement == "right" {
        return makeDirectoryTile(BASE.appendingPathComponent(g.name), label: g.name)
    }
    return makeAppTile(APPS.appendingPathComponent("\(g.name).app"), label: g.name)
}

// ─────────────────────────────────────────────── 同步

/// 该被同步的分组。`only` 为空 = 所有 `enabled` 分组（默认 True）。
func syncTargets(_ cfg: JSONObject, only: Set<String>?) -> [JSONObject] {
    cfg.groups.filter { g in
        if let o = only { return o.contains(g.name) }
        return g.enabled
    }
}

/// 把 tile 插到 anchor 对应条目之后；找不到锚点就追加到末尾。
private func insertAfter(_ tiles: inout [[String: Any]], _ tile: [String: Any],
                         anchor: String) {
    if let i = tiles.firstIndex(where: { tilePath($0) == anchor }) {
        tiles.insert(tile, at: i + 1)
        return
    }
    tiles.append(tile)
}

/// 把分组文件夹写进 Dock。
///
/// 位置策略：文件夹落在「被折叠的第一个 App 原来所在的位置」，不需手工配锚点。
/// （macOS 不允许拖文件夹进左侧 App 区，但手写 plist 是能被 Dock 接受的，实测通过。）
///
///   placement="left"  → 写进 persistent-apps（左侧 App 区）
///   placement="right" → 写进 persistent-others（分隔线右侧）
///   after=<App 路径>  → 可选，显式指定插在哪个 App 后面，覆盖自动落位
@discardableResult
func dockSync(_ cfg: JSONObject, only: Set<String>? = nil, prune: Bool = true) throws -> [String] {
    let tg = syncTargets(cfg, only: only)
    let pl = dockRead()
    let managed = Set(cfg.groups.map { $0.name })
    let original = pl["persistent-apps"] as? [[String: Any]] ?? []

    // 每组引用到的真实 App 路径
    var pathsOf: [String: Set<String>] = [:]
    for g in tg {
        var s = Set<String>()
        for (_, t, _) in readFolderApps(BASE.appendingPathComponent(g.name)) {
            s.insert(t.path)
            s.insert(t.resolvingSymlinksInPath().path)   // 对应 os.path.realpath
        }
        pathsOf[g.name] = s
    }
    let allGrouped = pathsOf.values.reduce(into: Set<String>()) { $0.formUnion($1) }

    func matches(_ tile: [String: Any], _ pset: Set<String>) -> Bool {
        guard let p = tilePath(tile), !p.isEmpty else { return false }
        return pset.contains(p)
            || pset.contains(URL(fileURLWithPath: p).resolvingSymlinksInPath().path)
    }

    // 自动落位：每组第一个 App 在原列表中的下标
    var firstPos: [Int: [JSONObject]] = [:]
    var fallback: [JSONObject] = []
    for g in tg {
        let pset = pathsOf[g.name] ?? []
        if let idx = original.firstIndex(where: { matches($0, pset) }) {
            firstPos[idx, default: []].append(g)
        } else {
            fallback.append(g)
        }
    }

    func keepLeft(_ t: [String: Any]) -> Bool {
        if let l = tileLabel(t), managed.contains(l) { return false }
        return !(prune && matches(t, allGrouped))
    }

    var left: [[String: Any]] = []
    for (i, t) in original.enumerated() {
        for g in firstPos[i] ?? [] where g.placement != "right" {
            left.append(tileFor(g))
        }
        if keepLeft(t) { left.append(t) }
    }

    var right = (pl["persistent-others"] as? [[String: Any]] ?? []).filter { t in
        if let l = tileLabel(t), managed.contains(l) { return false }
        return !(tilePath(t) ?? "").hasPrefix(BASE.path)
    }

    for g in fallback {
        if g.placement == "right" { right.append(tileFor(g)) } else { left.append(tileFor(g)) }
    }

    // 显式 after 覆盖
    for g in tg {
        guard let anchor = g["after"]?.stringValue, !anchor.isEmpty else { continue }
        left.removeAll { tileLabel($0) == g.name }
        insertAfter(&left, tileFor(g), anchor: anchor)
    }

    var out = pl
    out["persistent-apps"] = left
    out["persistent-others"] = right
    try dockWrite(out)
    return tg.map { $0.name }
}

/// 只从 Dock 里摘掉这几个分组的图标（不动其它条目）。
func dockRemove(_ names: [String]) throws {
    var pl = dockRead()
    let victims = Set(names)
    pl["persistent-others"] = (pl["persistent-others"] as? [[String: Any]] ?? []).filter {
        guard let l = tileLabel($0) else { return true }
        return !victims.contains(l)
    }
    try dockWrite(pl)
}
