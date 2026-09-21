// swift/Core/Group.swift
//
// 分组的组装：建别名、收成员、合成图标、设文件夹图标。
// 对应 Python 的 collect_apps / _folder_entries / set_folder_icon / build_group。
//
// 这里有两处原本走 JXA 的（mkalias / seticon），Swift 直接调 Foundation / AppKit。
// 底层是同一批 API，所以产物应当一致 —— 对照测试会验。

import Cocoa

/// 分组文件夹里除「图标载体」外的所有条目。
func folderEntries(_ folder: URL) -> [URL] {
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil) else { return [] }
    return items.filter {
        $0.lastPathComponent != ICON_ENTRY && !$0.lastPathComponent.hasPrefix(".")
    }
}

/// 批量建 Finder **真别名**（不是符号链接）。
/// 对应 Python 的 JXA "mkalias"。做真别名是因为 Dock 和 Finder 对别名与符号链接
/// 的处理不同，而分组文件夹里放的是 App 的替身，得和用户在 Finder 里自己拖出来的
/// 效果一致。
@discardableResult
func makeAliases(in folder: URL, _ targets: [URL]) -> [String] {
    var made: [String] = []
    let fm = FileManager.default
    for src in targets {
        var base = src.lastPathComponent
        if base.hasSuffix(".app") { base = String(base.dropLast(4)) }   // 别名不带 .app
        let dst = folder.appendingPathComponent(base)
        if fm.fileExists(atPath: dst.path) { made.append(base); continue }
        do {
            // 1024 = NSURLBookmarkCreationSuitableForBookmarkFile —— 写别名专用
            let data = try src.bookmarkData(options: .suitableForBookmarkFile,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            try URL.writeBookmarkData(data, to: dst)
            made.append(base)
        } catch {
            continue
        }
    }
    return made
}

/// 给文件夹设置自定义图标。
/// 对应 Python 的 JXA "seticon" —— 走 AppKit 官方 API，系统自己处理 icns / 资源分支，
/// 比自己往 `Icon\r` 里写要可靠。
@discardableResult
func setFolderIcon(_ folder: URL, _ png: URL) -> Bool {
    guard let img = NSImage(contentsOf: png) else { return false }
    return NSWorkspace.shared.setIcon(img, forFile: folder.path, options: [])
}

/// 文件夹优先；仅在**文件夹为空**时从配置播种一次，之后文件夹即唯一事实来源。
///
/// 为什么不「缺哪个补哪个」：那样用户手动删掉的别名会在下次 rebuild 时被配置里的
/// 旧列表重新播种回来，表现为「删了又自己出现」—— 与「文件夹是唯一事实来源」
/// 的承诺直接冲突。
func collectApps(_ g: JSONObject, folder: URL, seed: Bool = true)
    -> [(name: String, target: URL, isAlias: Bool)] {
    if seed {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if folderEntries(folder).isEmpty {
            let todo = g.apps.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            if !todo.isEmpty { makeAliases(in: folder, todo) }
        }
    }
    let apps = readFolderApps(folder)
    if !apps.isEmpty { return apps }
    return g.apps.compactMap { raw in
        let u = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return (name: u.deletingPathExtension().lastPathComponent, target: u, isAlias: false)
    }
}

/// 构建分组：合成拼贴图标（可选地设成文件夹图标）。
/// 返回 (文件夹, 图标 PNG, 有效清单, 缺失清单)。对应 Python 的 `build_group()`。
///
/// `seed` 的语义照抄 Python：`nil` → 按 `!iconsOnly` 决定；`true` → 允许播种；
/// `false` → **只刷新，绝不改变成员**（refresh 走这条）。
@discardableResult
func buildGroup(_ g: JSONObject, iconsOnly: Bool = false, style: String = DEFAULT_STYLE,
                seed: Bool? = nil) throws -> (folder: URL, mosaic: URL,
                                              ok: [(name: String, target: URL, isAlias: Bool)],
                                              missing: [String]) {
    let name = g.name
    let folder = BASE.appendingPathComponent(name)
    let doSeed = seed ?? !iconsOnly

    let apps = collectApps(g, folder: folder, seed: doSeed)
    if apps.isEmpty {
        throw DgError("分组「\(name)」里没有任何 App")
    }

    let missing = apps.filter { !FileManager.default.fileExists(atPath: $0.target.path) }.map(\.name)
    let ok = apps.filter { FileManager.default.fileExists(atPath: $0.target.path) }

    // ⚠️ 必须按 ok 的顺序取图标：appIcons 返回的是 Dictionary，而 Swift 的
    // Dictionary **无序**（Python 的 dict 是保序的）。直接拿 .values 的话图标顺序
    // 随机，拼贴图每个格子里放的 App 都不一样 —— 实测 MAE 直接飙到 21/255，
    // 而正常应该在 0.3。
    let iconMap = appIcons(ok.map(\.target))
    let iconURLs = ok.compactMap { iconMap[$0.target.path] }
    if iconURLs.isEmpty {
        throw DgError("分组「\(name)」未能提取到任何图标")
    }

    try? FileManager.default.createDirectory(at: CACHE, withIntermediateDirectories: true)
    let mosaic = CACHE.appendingPathComponent("\(name).png")
    makeMosaic(iconURLs.map(\.path), out: mosaic.path, style: style)

    if !iconsOnly { setFolderIcon(folder, mosaic) }
    return (folder, mosaic, ok, missing)
}
