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
///
/// `DOCKGROUP_SKIP_DOCK=1` 时整体跳过（不备份、不导入、不 killall、不写替身）：
/// 给 CI / 脚本化场景一个「只生成产物、绝不打扰 Dock」的总开关。
/// 与 DOCKGROUP_DOCK_PLIST 的区别：那个是**重定向**到替身文件，这个是**什么都不做**。
/// Python 版 dock_write 有同款开关，两边行为必须一致。
///
/// 「应用到 Dock」最让人烦的是**每次都全屏闪一下**（killall Dock 重启整个 Dock）。
/// 其实在配置一个字都没变的时候，重启纯属白闪 —— 所以写入前先和当前配置做一次
/// 深比较，完全一致就整段跳过。bookmark 字节已实测同引擎内确定（2026-09-22，
/// 同一 bundle 两次 bookmarkData 逐字节相等），可以放心当「内容没变」的判据；
/// 就算哪天系统让它变得不确定，最坏也只是退回「每次都重启」的旧行为，不会错。
func dockWrite(_ pl: [String: Any], rebuiltHint: Bool = false,
               finderRestart: Bool = true) throws {
    if ProcessInfo.processInfo.environment["DOCKGROUP_SKIP_DOCK"] == "1" {
        print("已跳过 Dock 写入（DOCKGROUP_SKIP_DOCK=1）")
        return
    }

    let data = try plistData(pl)

    // 无变化检测：用语义比较（NSDictionary 深比较），键序无关。
    // 注意必须 refresh 直读，不能用 _dockCache —— 缓存可能是同一条命令早前写的。
    // 替身模式（DOCKGROUP_DOCK_PLIST）也走这一条：替身文件没变同样不写。
    //
    // ⚠️ rebuildHint（2026-09-22 零闪模式）：bundle 重建后图标变了，但 Dock plist
    // 条目本身（bundle id / label / bookmark）不变 —— 这种「纯图标变化」**不重启
    // Dock**：killall 的黑帧+暗淡就是老大说的「闪两次」，而新版 icns 文件名保证了
    // 下次点击分组图标时立即显示新样式（实测确认）。dock.plist 变了才值得闪。
    // 比较用的副本：剥掉 tile-data["book"]。bookmark 是 bundle 内容的指纹，
    // 图标一变它就变 —— 但纯图标变化（icns 文件名已换新）根本不需要动 Dock 条，
    // 更不需要重启；把它算进「有变化」会白白闪一次。
    func normalized(_ pl: [String: Any]) -> NSDictionary {
        var copy = pl
        for key in ["persistent-apps", "persistent-others"] {
            guard let tiles = pl[key] as? [[String: Any]] else { continue }
            copy[key] = tiles.map { t in
                guard var td = t["tile-data"] as? [String: Any] else { return t }
                td.removeValue(forKey: "book")
                var t2 = t
                t2["tile-data"] = td
                return t2
            }
        }
        return copy as NSDictionary
    }

    if normalized(pl).isEqual(normalized(dockRead(refresh: true))) {
        if rebuiltHint {
            print("Dock 配置无变化，跳过重启（已重建的图标将在下次点击分组图标时显示）")
        } else {
            print("Dock 配置无变化，跳过重启")
        }
        _dockCacheSet(pl)
        return
    }

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
    // Finder 重启是「全屏闪第二次」的来源（桌面整个重绘）。只有动了分隔线
    // 右侧的文件夹 Stack（文件夹自定义图标需要 Finder 刷新）才值得付这个代价；
    // 左侧启动器分组跟 Finder 无关，不杀。（2026-09-22 老大报「闪两次」。）
    if finderRestart {
        run("/usr/bin/killall", ["Finder"])
    }
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
/// 位置策略（2026-09-22 重写）：
///   · 分组图标**已经在 Dock 上**的 → 原地替换，保住用户手动拖出来的顺序。
///     （旧实现是「删掉再按第一个成员 App 的位置重插」，手动挪过的位置每次
///     apply 都会被弹回原位 —— 老大报的 bug。）
///   · 新分组仍落在「被折叠的第一个 App 原来所在的位置」，不需手工配锚点。
///     （macOS 不允许拖文件夹进左侧 App 区，但手写 plist 是能被 Dock 接受的，实测通过。）
///
///   placement="left"  → 写进 persistent-apps（左侧 App 区）
///   placement="right" → 写进 persistent-others（分隔线右侧）
///   after=<App 路径>  → 可选，显式指定插在哪个 App 后面，覆盖自动落位
@discardableResult
func dockSync(_ cfg: JSONObject, only: Set<String>? = nil, prune: Bool = true,
              rebuilt: Bool = false) throws -> [String] {
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

    // 待写入的分组按 placement 分桶；「已在 Dock 上」的标记出来，
    // 它们不走 firstPos 自动落位（那正是把手动排序弹回去的元凶）。
    var pendingLeft: [String: JSONObject] = [:]
    var pendingRight: [String: JSONObject] = [:]
    for g in tg {
        if g.placement == "right" { pendingRight[g.name] = g } else { pendingLeft[g.name] = g }
    }
    func currentlyDocked(_ g: JSONObject) -> Bool {
        original.contains { tileLabel($0) == g.name }
            || ((pl["persistent-others"] as? [[String: Any]] ?? [])
                .contains { tileLabel($0) == g.name })
    }

    // 自动落位：只给**还不在 Dock 上**的新分组算；锚 = 每组第一个 App 在原列表中的下标
    var firstPos: [Int: [JSONObject]] = [:]
    var fallback: [JSONObject] = []
    for g in tg where !currentlyDocked(g) {
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

    var placed = Set<String>()        // 已经写进结果的分组名
    var replacedInPlace = Set<String>()  // 其中「原地替换」的那部分 —— after 不再动它们

    var left: [[String: Any]] = []
    for (i, t) in original.enumerated() {
        // 锚在这个下标的新分组：插在成员 App 前面（与旧版一致）
        for g in firstPos[i] ?? [] where g.placement != "right" {
            left.append(tileFor(g))
            placed.insert(g.name)
        }
        if let l = tileLabel(t) {
            if let g = pendingLeft[l] {
                left.append(tileFor(g))       // 原地替换：位置就是用户现在看到的这个
                placed.insert(l)
                replacedInPlace.insert(l)
                continue
            }
            if managed.contains(l) { continue }   // 分组被禁用/删除 → 照旧摘掉
        }
        if keepLeft(t) { left.append(t) }
    }

    var right: [[String: Any]] = []
    for t in (pl["persistent-others"] as? [[String: Any]] ?? []) {
        if let l = tileLabel(t) {
            if let g = pendingRight[l] {
                right.append(tileFor(g))      // 原地替换
                placed.insert(l)
                replacedInPlace.insert(l)
                continue
            }
            if managed.contains(l) { continue }
        }
        if (tilePath(t) ?? "").hasPrefix(BASE.path) { continue }
        right.append(t)
    }

    // 没锚点的兜底：新分组按 placement 追加到对应区末尾（与旧版一致）
    for g in fallback {
        if g.placement == "right" { right.append(tileFor(g)) } else { left.append(tileFor(g)) }
        placed.insert(g.name)
    }

    // placement 左右切换过、或其他边角情况：凡是 targets 里还没落位的，补到末尾
    for g in tg where !placed.contains(g.name) {
        if g.placement == "right" { right.append(tileFor(g)) } else { left.append(tileFor(g)) }
        placed.insert(g.name)
    }

    // 显式 after 覆盖 —— **只对首次落位的分组生效**。
    // 旧版每次 apply 都把所有配了 after 的分组拽回锚点，是「手动排序被重置」的
    // 另一半元凶（每个分组默认都带 after）。现在：分组已经在 Dock 上的，用户拖
    // 到哪就是哪；想重新按 after 落位，先 `dg remove` 再 apply。
    for g in tg where !replacedInPlace.contains(g.name) {
        guard let anchor = g["after"]?.stringValue, !anchor.isEmpty else { continue }
        left.removeAll { tileLabel($0) == g.name }
        insertAfter(&left, tileFor(g), anchor: anchor)
    }

    var out = pl
    out["persistent-apps"] = left
    out["persistent-others"] = right
    // Finder 只有在动了右侧文件夹 Stack 时才需要重启（见 dockWrite 内注释）
    try dockWrite(out, rebuiltHint: rebuilt,
                  finderRestart: tg.contains { $0.placement == "right" })
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
