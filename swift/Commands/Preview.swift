// swift/Commands/Preview.swift
//
// `dg preview` —— 合成分组图标并生成对比图。
// 对应 Python 的 cmd_preview / make_contact_sheet。
//
// make_contact_sheet 从 PIL 移植为 CoreGraphics：
//   · 缩放复用 Mosaic.swift 的 lanczos3Resize（PIL LANCZOS 的逐通道语义）
//   · 文字走 CoreText（字体候选与 Python 的 FONT_CANDIDATES 对齐，取首个可用）
//   · 文字光栅化两边引擎不同（FreeType vs CoreText），预览图是给人看的
//     开发工件，不是 Dock 资产 —— 对照只比布局与整体，阈值放宽到 3.0

import Cocoa

private let CONTACT_BIG = 176
private let CONTACT_SMALL = 64
private let CONTACT_PAD = 34

/// 与 Python FONT_CANDIDATES 对齐的字体候选（Hiragino W6/W3 → STHeiti →
/// PingFang → Helvetica），取第一个真实存在的 PostScript 名。
private func contactFont(_ size: CGFloat) -> CTFont {
    for name in ["HiraginoSansGB-W6", "HiraginoSansGB-W3",
                 "STHeitiSC-Medium", "PingFangSC-Regular", "Helvetica"] {
        let f = CTFontCreateWithName(name as CFString, size, nil)
        if (CTFontCopyPostScriptName(f) as String).caseInsensitiveCompare(name) == .orderedSame {
            return f
        }
    }
    return CTFontCreateWithName("Helvetica" as CFString, size, nil)
}

/// 拼贴对比图：每个分组一大一小两个图标 + 居中名字。
/// 对应 Python 的 make_contact_sheet(items, out)。
@discardableResult
func makeContactSheet(_ items: [(label: String, png: URL)], out: URL) -> URL {
    let big = CONTACT_BIG, small = CONTACT_SMALL, pad = CONTACT_PAD
    let w = max(560, pad + items.count * (big + pad))
    let h = pad + big + 46 + small + pad

    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return out }
    // PIL: Image.new("RGBA", (w, h), (255,255,255,255))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    let font = contactFont(26)
    var x = pad
    for (label, png) in items {
        // PIL: im.resize((big,big), LANCZOS) / ((small,small)) —— 复用验证过的实现
        guard let bmBig = loadBitmap(png.path, target: big),
              let bmSmall = loadBitmap(png.path, target: small) else { continue }
        // PIL 顶左 (x, pad) → CG 底左 (x, h - pad - big)；1:1 绘制不触发插值
        ctx.draw(cgImageRGBA(bmBig),
                 in: CGRect(x: x, y: h - pad - big, width: big, height: big))
        ctx.draw(cgImageRGBA(bmSmall),
                 in: CGRect(x: x + (big - small) / 2, y: h - (pad + big + 34) - small,
                            width: small, height: small))

        // PIL: d.text((x + (big - tw)/2, pad + big + 8), label) —— 锚点是「左上=ascender 顶」
        let line = makeCTLine(label, font: font)
        let tw = CTLineGetTypographicBounds(line, nil, nil, nil)
        let ascent = CTFontGetAscent(font)
        let baselineY = CGFloat(h) - (CGFloat(pad + big + 8) + ascent)
        ctx.textPosition = CGPoint(x: CGFloat(x) + (CGFloat(big) - tw) / 2, y: baselineY)
        CTLineDraw(line, ctx)

        x += big + pad
    }

    guard let img = ctx.makeImage() else { return out }
    writePNG(img, to: out.path)
    return out
}

private func makeCTLine(_ s: String, font: CTFont) -> CTLine {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: CGColor(red: 40 / 255.0, green: 40 / 255.0, blue: 45 / 255.0, alpha: 1),
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
}

func cmdPreview(_ cfg: JSONObject, _ args: [String]) {
    let only: Set<String>? = args.isEmpty ? nil : Set(args)
    let style = cfg.style
    var items: [(label: String, png: URL)] = []
    // 不带参数时预览全部分组（预览是只读操作，不受 enabled 限制）
    for g in cfg.groups where only == nil || only!.contains(g.name) {
        do {
            let r = try buildGroup(g, iconsOnly: true, style: style)
            items.append((g.name, r.mosaic))
            print("  已合成 \(g.name)（\(r.ok.count) 个 App）")
        } catch let e as DgError {
            print("  跳过 \(g.name)：\(e.message)")
            continue
        } catch {
            print("  跳过 \(g.name)：\(error)")
            continue
        }
    }
    if items.isEmpty {
        fatal("没有可预览的分组")
    }
    try? FileManager.default.createDirectory(at: CACHE, withIntermediateDirectories: true)
    let sheet = CACHE.appendingPathComponent("preview-all.png")
    makeContactSheet(items, out: sheet)
    print("\n预览对比图：\(sheet.path)")
}
