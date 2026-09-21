// swift/Core/AppIcon.swift
//
// 从 .app 提取图标 PNG（带缓存）。
// 对应 Python 的 _icon_cache / _shrink_cache / app_icons。
//
// Python 那边靠 osascript 跑 JXA 调 `NSWorkspace.iconForFile`，注释里还写着
// 「每起一个 osascript 做 AppKit 图标渲染约 400ms，逐 App 起进程是最大的性能坑」
// —— 它得先攒一批再一次性丢给 JXA。Swift 直接调同一个 API，那层进程和攒批
// 逻辑都不需要了，这是一个分组一次调用的差别。

import Cocoa

/// 图标缓存路径（按「文件名 + mtime」作 key）。App 不存在返回 nil。
/// Python 用 `int(app.stat().st_mtime)`，所以这里也要**截断到秒**，不能四舍五入。
func iconCachePath(_ app: URL) -> URL? {
    guard FileManager.default.fileExists(atPath: app.path) else { return nil }
    let name = app.deletingPathExtension().lastPathComponent
    var mtime = 0
    if let attrs = try? FileManager.default.attributesOfItem(atPath: app.path),
       let d = attrs[.modificationDate] as? Date {
        mtime = Int(d.timeIntervalSince1970)
    }
    return CACHE.appendingPathComponent("app-icons").appendingPathComponent("\(name)-\(mtime).png")
}

/// 把缓存里的原图缩到 ICON_SRC_PX，**原地替换**。
/// 写临时文件再替换，避免写坏缓存；缩略用和合成同一套 Lanczos，
/// 这里偷懒换插值算法的话，最终图标观感会跟着变。
func shrinkIconCache(_ png: URL) {
    guard let img = NSImage(contentsOf: png),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    guard max(cg.width, cg.height) > ICON_SRC_PX else { return }
    guard let small = loadBitmap(png.path, target: ICON_SRC_PX) else { return }

    // Python 用 png.with_suffix(".tmp.png") —— "A-123.png" → "A-123.tmp.png"
    let stem = png.deletingPathExtension().lastPathComponent
    let tmp = png.deletingLastPathComponent().appendingPathComponent("\(stem).tmp.png")
    writePNG(small, to: tmp.path)
    try? FileManager.default.removeItem(at: png)
    try? FileManager.default.moveItem(at: tmp, to: png)
}

/// 从一个 App 取图标写成 PNG。对应 Python 的 JXA "grab"。
///
/// 走 `NSWorkspace.icon(forFile:)` 而不是去翻 `Contents/Resources/*.icns` ——
/// 前者能正确处理 Assets.car，后者在不少 App（尤其系统 App）上会拿到空图标。
@discardableResult
func grabIcon(from app: URL, to out: URL) -> Bool {
    let icon = NSWorkspace.shared.icon(forFile: app.path)
    icon.size = NSSize(width: 1024, height: 1024)
    guard let tiff = icon.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return false }
    // 对应 JXA 的 writeToFileAtomically(_, true)
    return (try? png.write(to: out, options: .atomic)) != nil
}

/// 批量取图标 → [App 路径: 图标 PNG 路径]。缺哪个补哪个，已有的直接复用缓存。
/// 对应 Python 的 `app_icons()`。
func appIcons(_ apps: [URL]) -> [String: URL] {
    var jobs: [(app: URL, out: URL)] = []
    for a in apps {
        guard let out = iconCachePath(a) else { continue }
        jobs.append((a, out))
    }

    // 不存在、或者存在但是 0 字节 → 需要重新抓
    var pending: [(app: URL, out: URL)] = []
    for j in jobs {
        let size = ((try? FileManager.default.attributesOfItem(atPath: j.out.path))?[.size]
                    as? Int) ?? 0
        if size == 0 { pending.append(j) }
    }

    if !pending.isEmpty {
        try? FileManager.default.createDirectory(
            at: CACHE.appendingPathComponent("app-icons"), withIntermediateDirectories: true)
        for j in pending { grabIcon(from: j.app, to: j.out) }
        // 去重：多个 App 可能指向同一个缓存文件（比如同一个 App 被加了两次）
        for path in Set(jobs.map { $0.out.path }) {
            shrinkIconCache(URL(fileURLWithPath: path))
        }
    }

    var result: [String: URL] = [:]
    for j in jobs {
        let size = ((try? FileManager.default.attributesOfItem(atPath: j.out.path))?[.size]
                    as? Int) ?? 0
        if size > 0 { result[j.app.path] = j.out }
    }
    return result
}
