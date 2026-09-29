// swift/Core/Icns.swift
//
// PNG → .icns。对应 Python 的 png_to_icns()。
//
// 迁移期照抄 sips + iconutil 这条路，不是偷懒：
//   · icns 的封装有 modern / legacy 好几种变体，`CGImageDestination` 写出来的
//     和 iconutil 不见得一致，而我们要求产物**可控可预期**。要替换得先单独
//     做一次逐字节对照，不能顺手换。
//   · sips / iconutil 都是 macOS 自带（**不在** CLT 里 —— 2026-09-21 实测：
//     `xcrun -f iconutil` 解析回 /usr/bin/iconutil），所以留着也不增加依赖。

import Foundation

/// PNG → .icns。10 档尺寸和 Python 版一字不差。
/// iconutil 失败必须报错（与 Python 的 `sh(..., check=True)` 同款）：
/// 调用方在打包前已把旧 `AppIcon*.icns` 清掉 —— 静默失败会让 Info.plist 里的
/// CFBundleIconFile 悬空，Dock 显示通用图标还当构建成功。（2026-09-29 改。）
func pngToIcns(_ png: URL, _ icns: URL) throws -> URL {
    let fm = FileManager.default
    let td = fm.temporaryDirectory.appendingPathComponent("dg-icns-\(UUID().uuidString)")
    let iconset = td.appendingPathComponent("icon.iconset")
    try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    // 顺序也照抄：sips 一档档生成，最后 iconutil 打包整个 iconset。
    let sizes: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for (fname, px) in sizes {
        run("/usr/bin/sips", ["-z", String(px), String(px), png.path,
                              "--out", iconset.appendingPathComponent(fname).path])
    }

    try? fm.createDirectory(at: icns.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    let r = run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    try? fm.removeItem(at: td)   // 对应 Python 的 TemporaryDirectory 自动清理
    guard r.ok, fm.fileExists(atPath: icns.path) else {
        throw DgError("iconutil 打包 .icns 失败：\(icns.path)\n\(r.errText)")
    }
    return icns
}
