// swift/Core/Mosaic.swift
//
// 分组图标的合成 —— make_mosaic() / _panel_base() 的 Swift 实现。
//
// 这份代码是从 tools/mosaic_poc 那个可行性验证原型搬过来的，与 Pillow 做过
// 逐像素对比（5 风格 × 1~4 图标 = 20 组，MAE 0.19~0.30/255、PSNR 60.9~62.3 dB）。
// 搬家时只去掉了 CLI 入口和重复的路径常量，**合成逻辑一个字没改** ——
// 那条误差曲线是好几轮试错才压下去的，别顺手"优化"。
//
// ⚠️ 下面几处是 PIL 的语义，和 CoreGraphics 的默认行为**不一样**。必须照抄，
// 否则图看着像、逐像素一比就差一大截：
//   · `paste(color, (0,0), mask)` 不是 source-over，而是**逐通道线性插值**
//     out[c] = src[c]*m + dst[c]*(1-m)，alpha 通道也参与。
//   · 竖直渐变是 top + (bottom-top)*y/(size-1)，逐行取整，不是「建 1x2 再放大」。
//   · 底板只占 85% 边长（ICON_INSET），不是铺满画布。
//   · PIL 的矩形是**闭区间**（含右下端点），CGRect 是半开区间 —— 差这 1 像素，
//     表现是「底板只有右边缘和下边缘出现差异带」。
//   · PIL 的 GaussianBlur 其实是 **3 次 box blur 近似**，不是精确高斯。
//   · 色彩空间要用源图自己的（macOS 图标都是 Display P3），写死 sRGB 会被
//     CoreGraphics 静默转换 —— 这一条的影响比其余所有加起来还大。
//
// 每一条的踩坑经过和量化数据见 references/spike-swift-mosaic.md。

import Accelerate
import Cocoa

// ───────────────────────────────────────────────── 常量（抄自 dockgroup.py）

// ICON_INSET / BG_RADIUS 在 Core/Paths.swift 里定义，这里不要重复定义。

struct RGBA {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    init(_ t: (Int, Int, Int, Int)) {
        self.init(Double(t.0), Double(t.1), Double(t.2), Double(t.3))
    }
}

struct Style {
    var bg: (RGBA, RGBA)?
    var hair: RGBA?
    var edge: (RGBA, Double)?
    var cell: Double
    var pad: Double
    var gap: Double
    var shadow: Bool
    var iconShadow: Bool
}

let STYLES: [String: Style] = [
    "dock": Style(
        bg: (RGBA((225, 227, 234, 252)), RGBA((198, 201, 213, 253))),
        hair: RGBA((255, 255, 255, 200)), edge: (RGBA((122, 126, 141, 135)), 0.0025),
        cell: 0.440, pad: 0.085, gap: 0.045, shadow: true, iconShadow: true),
    "dock-deep": Style(
        bg: (RGBA((209, 212, 221, 252)), RGBA((176, 180, 194, 253))),
        hair: RGBA((255, 255, 255, 205)), edge: (RGBA((104, 108, 124, 150)), 0.0025),
        cell: 0.440, pad: 0.085, gap: 0.045, shadow: true, iconShadow: true),
    "paper": Style(
        bg: (RGBA((255, 255, 255, 253)), RGBA((238, 239, 244, 253))),
        hair: RGBA((255, 255, 255, 225)), edge: (RGBA((146, 149, 160, 135)), 0.0022),
        cell: 0.440, pad: 0.085, gap: 0.045, shadow: true, iconShadow: true),
    "frost-light": Style(
        bg: (RGBA((248, 249, 252, 248)), RGBA((196, 201, 213, 251))),
        hair: RGBA((255, 255, 255, 205)), edge: (RGBA((112, 116, 132, 115)), 0.0025),
        cell: 0.440, pad: 0.085, gap: 0.045, shadow: true, iconShadow: true),
    "frost-blue": Style(
        bg: (RGBA((224, 235, 251, 249)), RGBA((154, 182, 222, 251))),
        hair: RGBA((255, 255, 255, 210)), edge: (RGBA((74, 108, 158, 120)), 0.0025),
        cell: 0.440, pad: 0.085, gap: 0.045, shadow: true, iconShadow: true),
    "glass-dark": Style(
        bg: (RGBA((90, 91, 101, 249)), RGBA((28, 29, 35, 252))),
        hair: RGBA((255, 255, 255, 125)), edge: (RGBA((0, 0, 0, 145)), 0.0025),
        cell: 0.440, pad: 0.085, gap: 0.045, shadow: true, iconShadow: false),
    "graphite": Style(
        bg: (RGBA((124, 126, 136, 250)), RGBA((68, 70, 80, 252))),
        hair: RGBA((255, 255, 255, 155)), edge: (RGBA((0, 0, 0, 155)), 0.0025),
        cell: 0.440, pad: 0.085, gap: 0.045, shadow: true, iconShadow: false),
]
// DEFAULT_STYLE 定义在 Core/Config.swift（和 Python 的 DEFAULT_STYLE 对齐），
// 这里不要重复定义 —— 单独定义一份的话，哪天默认风格改了会漏改这一处。

// ───────────────────────────────────────────────── 像素缓冲

/// 非预乘 RGBA8 位图。索引 = (y*size + x)*4。
struct Bitmap {
    let size: Int
    var px: [UInt8]

    init(size: Int, fill: RGBA = RGBA(0, 0, 0, 0)) {
        self.size = size
        self.px = [UInt8](repeating: 0, count: size * size * 4)
        if fill.a > 0 || fill.r > 0 || fill.g > 0 || fill.b > 0 {
            for i in stride(from: 0, to: px.count, by: 4) {
                px[i] = UInt8(fill.r); px[i + 1] = UInt8(fill.g)
                px[i + 2] = UInt8(fill.b); px[i + 3] = UInt8(fill.a)
            }
        }
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
        let i = (y * size + x) * 4
        return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]), Double(px[i + 3]))
    }

    @inline(__always) mutating func set(_ x: Int, _ y: Int, _ c: (Double, Double, Double, Double)) {
        let i = (y * size + x) * 4
        px[i] = UInt8(clamping: Int(c.0.rounded()))
        px[i + 1] = UInt8(clamping: Int(c.1.rounded()))
        px[i + 2] = UInt8(clamping: Int(c.2.rounded()))
        px[i + 3] = UInt8(clamping: Int(c.3.rounded()))
    }

    /// PIL `paste(color, (0,0), mask)` 的语义：**逐通道**线性插值
    /// out[c] = src[c]*m + dst[c]*(1-m)，alpha 通道也按同一系数混合。
    /// 注意这不是 source-over —— 照 source-over 实现会和 Pillow 差一大截。
    mutating func blend(color: RGBA, mask: [Double], strength: Double = 1.0) {
        for y in 0..<size {
            for x in 0..<size {
                let raw = mask[y * size + x] * strength
                let m = min(max(raw, 0), 255) / 255.0
                if m <= 0 { continue }
                let (dr, dg, db, da) = at(x, y)
                set(x, y, (color.r * m + dr * (1 - m),
                           color.g * m + dg * (1 - m),
                           color.b * m + db * (1 - m),
                           color.a * m + da * (1 - m)))
            }
        }
    }

    /// 标准 source-over 合成（对应 PIL 的 `alpha_composite`）。
    mutating func compositeOver(_ src: Bitmap, at ox: Int, oy: Int) {
        for y in 0..<src.size {
            let dy = oy + y
            if dy < 0 || dy >= size { continue }
            for x in 0..<src.size {
                let dx = ox + x
                if dx < 0 || dx >= size { continue }
                let (sr, sg, sb, sa) = src.at(x, y)
                if sa <= 0 { continue }
                let a = sa / 255.0
                let (dr, dg, db, da) = at(dx, dy)
                let outA = a + (da / 255.0) * (1 - a)
                if outA <= 0 { set(dx, dy, (0, 0, 0, 0)); continue }
                // 非预乘 source-over
                let r = (sr * a + dr * (da / 255.0) * (1 - a)) / outA
                let g = (sg * a + dg * (da / 255.0) * (1 - a)) / outA
                let b = (sb * a + db * (da / 255.0) * (1 - a)) / outA
                set(dx, dy, (r, g, b, outA * 255))
            }
        }
    }
}

// ───────────────────────────────────────────────── CG 光栅化（取 mask）

/// 用 CoreGraphics 光栅化一段灰度绘制，返回 size×size 的 0-255 mask。
/// 圆角矩形这类带抗锯齿的形状交给 CG 画，比自己写扫描线稳。
func grayMask(size: Int, _ draw: (CGContext) -> Void) -> [Double] {
    var buf = [UInt8](repeating: 0, count: size * size)
    buf.withUnsafeMutableBytes { raw in
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        draw(ctx)
    }
    return buf.map { Double($0) }
}

func roundedRectPath(_ box: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// PIL 的 `ImageDraw.rounded_rectangle(..., outline:, width:)` 是**向内**描边。
/// CG 的 `strokePath` 是沿路径**居中**描边，所以要内缩半个线宽来对齐。
func strokeRoundedInset(ctx: CGContext, box: CGRect, radius: CGFloat,
                        width: CGFloat, gray: CGFloat) {
    let inset = width / 2.0
    let r = max(radius - inset, 0)
    let b = box.insetBy(dx: inset, dy: inset)
    ctx.setStrokeColor(gray: gray, alpha: 1)
    ctx.setLineWidth(width)
    ctx.addPath(roundedRectPath(b, radius: r))
    ctx.strokePath()
}

// ───────────────────────────────────────────────── 高斯模糊

/// 对灰度 mask 做高斯模糊。sigma 直接对应 PIL `GaussianBlur(radius)` 的 radius。
/// 复现 PIL 的 `ImageFilter.GaussianBlur(radius)`。
///
/// 关键：PIL 的「高斯模糊」**不是**精确高斯，而是 **3 次 box blur 近似**
/// （Ivan Kutskir 那套经典算法，Pillow 的 BoxBlur.c 用的就是它）。
/// 所以拿 CIGaussianBlur 去对反而对不齐 —— 实测带图标投影的风格差异到 9.5%，
/// 不带投影的只有 0.5%，差的就是这一步。换成 box blur ×3 后两边同步下降。
///
/// 半径推导照抄该算法：
///   wIdeal = sqrt(12σ²/n + 1)，wl 向下取整到奇数，wu = wl + 2，
///   再按 m 决定前几次用 wl、后几次用 wu。
func blurMask(_ src: [Double], size: Int, sigma: Double) -> [Double] {
    guard sigma > 0.01 else { return src }
    let n = 3
    let wIdeal = (12.0 * sigma * sigma / Double(n) + 1.0).squareRoot()
    var wl = Int(wIdeal.rounded(.down))
    if wl % 2 == 0 { wl -= 1 }
    if wl < 1 { wl = 1 }
    let wu = wl + 2
    let mIdeal = (12.0 * sigma * sigma - Double(n * wl * wl)
                  - Double(4 * n * wl) - Double(3 * n)) / Double(-4 * wl - 4)
    let m = Int(mIdeal.rounded())
    var sizes = [Int]()
    for i in 0..<n { sizes.append(i < m ? wl : wu) }

    var cur = src.map { UInt8(clamping: Int($0.rounded())) }
    for k in sizes { cur = boxBlurGray(cur, size: size, kernel: k) }
    return cur.map { Double($0) }
}

/// 单次 box blur，边界复制（对应 PIL 的边界语义）。
func boxBlurGray(_ src: [UInt8], size: Int, kernel: Int) -> [UInt8] {
    guard kernel > 1 else { return src }
    var srcCopy = src
    var dst = [UInt8](repeating: 0, count: size * size)
    srcCopy.withUnsafeMutableBytes { sp in
        dst.withUnsafeMutableBytes { dp in
            var sb = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(size),
                                   width: vImagePixelCount(size), rowBytes: size)
            var db = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(size),
                                   width: vImagePixelCount(size), rowBytes: size)
            vImageBoxConvolve_Planar8(&sb, &db, nil, 0, 0,
                                      UInt32(kernel), UInt32(kernel),
                                      0, vImage_Flags(kvImageEdgeExtend))
        }
    }
    return dst
}

// ───────────────────────────────────────────────── 底板 / 拼贴

/// 竖直渐变：`top + (bottom-top)*y/(size-1)`，逐行取整。
/// 照抄 Python 的写法，别改成「建 1x2 再放大」—— 那会对不齐。
func verticalGradient(size: Int, top: RGBA, bottom: RGBA) -> Bitmap {
    var bm = Bitmap(size: size)
    let span = max(size - 1, 1)
    for y in 0..<size {
        let t = Double(y) / Double(span)
        // Python 的 int() 是向零截断
        let r = Int(top.r + (bottom.r - top.r) * t)
        let g = Int(top.g + (bottom.g - top.g) * t)
        let bl = Int(top.b + (bottom.b - top.b) * t)
        let a = Int(top.a + (bottom.a - top.a) * t)
        for x in 0..<size { bm.set(x, y, (Double(r), Double(g), Double(bl), Double(a))) }
    }
    return bm
}

/// PIL 的矩形是**闭区间**语义：`rounded_rectangle((x0,y0,x1,y1))` 覆盖 x0..x1
/// **含两端**，宽度是 `x1-x0+1`。CG 的 CGRect 是半开区间 `[x, x+w)`。
/// 差这一个像素，直接表现成「底板右边缘和下边缘各有一条差异带，左边和上边却干净」。
func pilRect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> CGRect {
    CGRect(x: CGFloat(x0), y: CGFloat(y0),
           width: CGFloat(x1 - x0 + 1), height: CGFloat(y1 - y0 + 1))
}

/// Python 的 `//` 是**向下取整**，Swift 的 `/` 是**向零取整** —— 负数时差 1。
/// n==2 的布局里 `(side - 2*cell - gap) // 2` 恰好是负数，这一个像素让两个图标
/// 整体错位（实测 n=2 的差异一直是其它布局的 4 倍，就是它）。
/// 凡是照抄 Python `//` 的地方都要过这个函数。
func pilDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    if a % b != 0 && ((a < 0) != (b < 0)) { return q - 1 }
    return q
}

func panelBase(S: Int, st: Style) -> Bitmap {
    let inset = Int(Double(S) * ICON_INSET)
    let side = S - 2 * inset
    let radius = Int(Double(side) * BG_RADIUS)
    // PIL 的 box 是 (inset, inset, S-inset, S-inset)，闭区间
    let box = pilRect(inset, inset, S - inset, S - inset)

    var canvas = Bitmap(size: S)

    // 投影：让图标从 Dock 上浮起来
    if st.shadow {
        let padSh = Int(Double(S) * 0.030)
        let dy = Int(Double(S) * 0.012)
        let inner = pilRect(inset + padSh, inset + padSh + dy,
                            S - inset - padSh, S - inset - padSh + dy)
        var m = grayMask(size: S) { ctx in
            ctx.setFillColor(gray: 150.0 / 255.0, alpha: 1)
            ctx.addPath(roundedRectPath(inner, radius: CGFloat(radius)))
            ctx.fillPath()
        }
        m = blurMask(m, size: S, sigma: Double(Int(Double(S) * 0.022)))
        canvas.blend(color: RGBA(24, 26, 34, 255), mask: m)
    }

    // 底板（渐变 + 圆角裁切）
    if let (t, b) = st.bg {
        let grad = verticalGradient(size: S, top: t, bottom: b)
        let m = grayMask(size: S) { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(roundedRectPath(box, radius: CGFloat(radius)))
            ctx.fillPath()
        }
        // 等价于 canvas.paste(grad, (0,0), mask)：逐通道线性插值
        for y in 0..<S {
            for x in 0..<S {
                let mm = min(max(m[y * S + x], 0), 255) / 255.0
                if mm <= 0 { continue }
                let (gr, gg, gb, ga) = grad.at(x, y)
                let (dr, dg, db, da) = canvas.at(x, y)
                canvas.set(x, y, (gr * mm + dr * (1 - mm), gg * mm + dg * (1 - mm),
                                  gb * mm + db * (1 - mm), ga * mm + da * (1 - mm)))
            }
        }
    }

    // 描边部分：PIL 的 ImageDraw 是**直接写像素**（mask=255 处等同覆盖），
    // 所以先光栅化成 mask，再用各描边自己的颜色混上去。
    // 坐标要翻转 —— PIL 是左上原点，CG 是左下原点。
    // 用 PIL 的坐标写路径、经这一次翻转，落到的行才和 PIL 一致。
    if let hair = st.hair {
        let w = CGFloat(max(2, Int(Double(S) * 0.0045)))
        let m = grayMask(size: S) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(S))
            ctx.scaleBy(x: 1, y: -1)
            strokeRoundedInset(ctx: ctx, box: box, radius: CGFloat(radius),
                               width: w, gray: 1)
        }
        canvas.blend(color: hair, mask: m)
    }
    if let (col, o) = st.edge {
        let off = max(1, Int(Double(S) * o))
        let outer = pilRect(inset - off, inset - off, S - inset + off, S - inset + off)
        let m = grayMask(size: S) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(S))
            ctx.scaleBy(x: 1, y: -1)
            strokeRoundedInset(ctx: ctx, box: outer, radius: CGFloat(radius + off),
                               width: CGFloat(off), gray: 1)
        }
        canvas.blend(color: col, mask: m)
    }

    return canvas
}

// ───────────────────────────────────────────────── 主流程

/// PIL `Image.resize(..., Image.LANCZOS)` 的等效实现（Lanczos-3，separable）。
///
/// 为什么不用现成的：
///   · `CGContext.interpolationQuality = .high` 只是双线性类，差得明显。
///   · `CILanczosScaleTransform` 虽然是真 Lanczos，但 CI 在**预乘 + 线性色彩空间**
///     里插值，PIL 是对 R/G/B/A **逐通道独立、直接拿 8bit 值**做。
///     半透明边缘处两者结果必然不同 —— 实测换 CI 只把 MAE 从 1.90 降到 1.85。
/// 所以照 PIL 的 precompute_coeffs 语义自己写：scale = in/out，filterscale 取
/// max(scale,1)，support = 3*filterscale，权重归一化，逐通道独立。
func lanczos3Resize(_ src: Bitmap, to target: Int) -> Bitmap {
    let inSize = src.size
    if inSize == target { return src }
    let scale = Double(inSize) / Double(target)
    let filterscale = max(scale, 1.0)
    let support = 3.0 * filterscale
    let ss = 1.0 / filterscale

    @inline(__always) func kern(_ x: Double) -> Double {
        if x == 0 { return 1.0 }
        if x <= -3.0 || x >= 3.0 { return 0.0 }
        let px = Double.pi * x
        return 3.0 * sin(px) * sin(px / 3.0) / (px * px)
    }

    var coeffs = [[Double]]()
    var lo = [Int]()
    coeffs.reserveCapacity(target)
    for xx in 0..<target {
        let center = (Double(xx) + 0.5) * scale
        var xmin = Int(center - support + 0.5)
        if xmin < 0 { xmin = 0 }
        var xmax = Int(center + support + 0.5)
        if xmax > inSize { xmax = inSize }
        var w = [Double]()
        var wsum = 0.0
        for x in xmin..<xmax {
            let v = kern((Double(x) - center + 0.5) * ss)
            w.append(v); wsum += v
        }
        if wsum != 0 { for i in 0..<w.count { w[i] /= wsum } }
        coeffs.append(w); lo.append(xmin)
    }

    // 水平
    var tmp = [Double](repeating: 0, count: target * inSize * 4)
    for y in 0..<inSize {
        let rowBase = y * inSize * 4
        for xx in 0..<target {
            let w = coeffs[xx], x0 = lo[xx]
            for c in 0..<4 {
                var acc = 0.0
                for (i, k) in w.enumerated() {
                    acc += Double(src.px[rowBase + (x0 + i) * 4 + c]) * k
                }
                tmp[(y * target + xx) * 4 + c] = acc
            }
        }
    }

    // 垂直
    var out = Bitmap(size: target)
    for yy in 0..<target {
        let w = coeffs[yy], y0 = lo[yy]
        for x in 0..<target {
            let base = (x * 4)
            for c in 0..<4 {
                var acc = 0.0
                for (i, k) in w.enumerated() {
                    acc += tmp[((y0 + i) * target) * 4 + base + c] * k
                }
                out.px[(yy * target + x) * 4 + c] = UInt8(clamping: Int(acc.rounded()))
            }
        }
    }
    return out
}

func loadBitmap(_ path: String, target: Int) -> Bitmap? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        // ⚠️ 色彩空间必须用**源图自己的**，不能写死 DeviceRGB。
        // macOS 的 App 图标都是 Display P3，写死 sRGB 会让 CoreGraphics 悄悄做一次
        // P3→sRGB 转换，而 PIL 是直接拿原始数值、根本不做转换 —— 两边颜色就对不上了。
        // 实测这一个差异能到「R 通道 3.8% 的像素差 >32」，比所有插值误差加起来还大。
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // 按**原始尺寸**画，别在这里顺手缩放 —— 缩放交给 lanczos3Resize
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var src = Bitmap(size: w)
    for i in stride(from: 0, to: buf.count, by: 4) {
        let a = Double(buf[i + 3])
        if a <= 0 { continue }
        src.px[i] = UInt8(clamping: Int((Double(buf[i]) * 255.0 / a).rounded()))
        src.px[i + 1] = UInt8(clamping: Int((Double(buf[i + 1]) * 255.0 / a).rounded()))
        src.px[i + 2] = UInt8(clamping: Int((Double(buf[i + 2]) * 255.0 / a).rounded()))
        src.px[i + 3] = buf[i + 3]
    }
    return lanczos3Resize(src, to: target)
}

func writePNG(_ bm: Bitmap, to path: String) {
    writePNG(cgImageRGBA(bm), to: path)
}

/// Bitmap（非预乘 RGBA）→ CGImage。与 writePNG 的转换逻辑一致，供
/// 需要把中间位图再画进 CGContext 的场景（contact sheet）复用。
func cgImageRGBA(_ bm: Bitmap) -> CGImage {
    // 非预乘 → 预乘（CG 只吃预乘）
    var buf = [UInt8](repeating: 0, count: bm.px.count)
    for i in stride(from: 0, to: bm.px.count, by: 4) {
        let a = Double(bm.px[i + 3])
        buf[i] = UInt8(clamping: Int((Double(bm.px[i]) * a / 255.0).rounded()))
        buf[i + 1] = UInt8(clamping: Int((Double(bm.px[i + 1]) * a / 255.0).rounded()))
        buf[i + 2] = UInt8(clamping: Int((Double(bm.px[i + 2]) * a / 255.0).rounded()))
        buf[i + 3] = bm.px[i + 3]
    }
    let provider = CGDataProvider(data: Data(buf) as CFData)!
    return CGImage(width: bm.size, height: bm.size, bitsPerComponent: 8,
                   bitsPerPixel: 32, bytesPerRow: bm.size * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

/// CGImage → PNG（任意尺寸；contact sheet 这类非方形画布用）。
func writePNG(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// 把若干 App 图标合成一张分组图标，写到 `out`。
/// 对应 Python 的 `make_mosaic(icon_paths, out, size=1024, style=...)`，
/// 签名也保持一致（参数顺序、默认值）。
@discardableResult
func makeMosaic(_ icons: [String], out: String, size S: Int = 1024,
                style: String = DEFAULT_STYLE) -> String {
    let st = STYLES[style] ?? STYLES[DEFAULT_STYLE]!
    var canvas = panelBase(S: S, st: st)
    let inset = Int(Double(S) * ICON_INSET)
    let side = S - 2 * inset

    let pad = Int(Double(side) * st.pad)
    var gap = Int(Double(side) * st.gap)
    let n = icons.count
    var cell = pilDiv(side - 2 * pad - gap, 2)
    var slots: [(Int, Int)] = []

    if n == 1 {
        cell = Int(Double(side) * 0.62)
        let c = pilDiv(side - cell, 2)
        slots = [(c, c)]
    } else if n == 2 {
        cell = Int(Double(side) * 0.55)
        gap = Int(Double(side) * 0.08)
        // 这里必须用 pilDiv：side - 2*cell - gap 是负数，Python 的 // 向下取整
        let x0 = pilDiv(side - 2 * cell - gap, 2)
        let y0 = pilDiv(side - cell, 2)
        slots = [(x0, y0), (x0 + cell + gap, y0)]
    } else {
        slots = [(pad, pad), (pad + cell + gap, pad),
                 (pad, pad + cell + gap), (pad + cell + gap, pad + cell + gap)]
    }
    for (i, ip) in icons.prefix(4).enumerated() {
        guard let ic = loadBitmap(ip, target: cell) else { continue }
        let pos = (inset + slots[i].0, inset + slots[i].1)
        if st.iconShadow {
            // _drop_shadow：把图标的 alpha 下移一点、模糊、乘 strength，再 paste
            var m = [Double](repeating: 0, count: S * S)
            let off = max(1, Int(Double(S) * 0.007))
            for y in 0..<cell {
                let dy = pos.1 + y + off
                if dy < 0 || dy >= S { continue }
                for x in 0..<cell {
                    let dx = pos.0 + x
                    if dx < 0 || dx >= S { continue }
                    m[dy * S + dx] = Double(ic.px[(y * cell + x) * 4 + 3])
                }
            }
            m = blurMask(m, size: S, sigma: Double(max(2, Int(Double(S) * 0.011))))
            for i2 in 0..<(S * S) { m[i2] = Double(Int(m[i2] * 0.34)) }
            canvas.blend(color: RGBA(30, 32, 42, 255), mask: m)
        }
        canvas.compositeOver(ic, at: pos.0, oy: pos.1)
    }

    writePNG(canvas, to: out)
    return out
}
