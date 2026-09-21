// swift/Core/Plist.swift
//
// 保序 XML plist 序列化。
//
// 为什么不能用 PropertyListSerialization：它接受的是 `[String: Any]`，而 Swift 的
// 字典**不保序**，String 的哈希还带 per-process 随机种子 —— 同一个程序跑两次，
// 键顺序都可能不同。
//
// 这不只是 diff 噪声的问题。启动器的 Info.plist 里有一个 `CFBundleVersion`，
// 它是按**内容摘要**算出来的（改了内容版本号才变，Dock 才会刷新图标缓存）。
// 如果 plist 的字节顺序每次都变，摘要就每次都变 → 每次 rebuild 都白白刷一遍
// Dock 图标。所以必须把键顺序钉死。
//
// 输出格式对齐 Python 的 `plistlib.dumps()`：XML、tab 缩进、同样的 DOCTYPE。

import Foundation

indirect enum PlistValue {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case data(Data)
    case dict([(String, PlistValue)])   // 保序
    case array([PlistValue])

    /// 序列化成 XML plist 的字节。
    func xmlData() -> Data {
        // 头部要和 plistlib **逐字符**一致：`<plist version="1.0">` 后面只有**一个**
        // 换行，紧跟根节点、且根节点不缩进。多一个空行，摘要就对不上了。
        //
        // 另外 plistlib 默认 `sort_keys=True`，所以键是**排好序**的 ——
        // 调用方构造 dict 时就要按 key 排序，别指望序列化器替你排。
        let head = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        """#
        return Data((head + "\n" + render(indent: 0) + "\n</plist>\n").utf8)
    }

    private func render(indent: Int) -> String {
        let pad = String(repeating: "\t", count: indent)
        switch self {
        case .string(let s):
            return pad + "<string>" + xmlEscape(s) + "</string>"
        case .bool(let b):
            return pad + (b ? "<true/>" : "<false/>")
        case .integer(let n):
            return pad + "<integer>\(n)</integer>"
        case .real(let d):
            // ⚠️ 对应 Python 的 `repr(value)`。Swift 的 `"\(d)"` 和 Python 的 repr
            // 都是「最短可往返」表示，常规数值一致（71.0 → `71.0`、0.1 → `0.1`），
            // 但极端值上不保证逐位相同 —— Dock 配置里的浮点只有 largesize 那几个
            // 和 last-analytics-stamp，实测一致。
            return pad + "<real>\(d)</real>"
        case .data(let d):
            return renderData(d, indent: indent, pad: pad)
        case .array(let items):
            if items.isEmpty { return pad + "<array/>" }
            return pad + "<array>\n"
                + items.map { $0.render(indent: indent + 1) }.joined(separator: "\n")
                + "\n" + pad + "</array>"
        case .dict(let pairs):
            if pairs.isEmpty { return pad + "<dict/>" }
            let body = pairs.map { key, value in
                pad + "\t<key>" + xmlEscape(key) + "</key>\n" + value.render(indent: indent + 1)
            }.joined(separator: "\n")
            return pad + "<dict>\n" + body + "\n" + pad + "</dict>"
        }
    }
}

/// `<data>` 的写法，逐条对应 plistlib 的 `_PlistWriter.write_bytes()`：
///   · `maxlinelength = max(16, 76 - 8 * 缩进层级)` —— plistlib 是按**空格**折算
///     缩进宽度的（每个 \t 当 8 个空格），不是数制表符个数
///   · 每行装 `(maxlinelength // 4) * 3` 字节的 base64，行宽正好等于 maxlinelength
///   · base64 行的缩进和 `<data>` 自己**同级**（不再缩进一层）
///   · 空数据写成 `<data>` 紧接 `</data>`，中间不留空行
private func renderData(_ d: Data, indent: Int, pad: String) -> String {
    let maxLen = max(16, 76 - 8 * indent)
    let chunk = (maxLen / 4) * 3
    var lines: [String] = []
    var i = d.startIndex
    while i < d.endIndex {
        let j = d.index(i, offsetBy: chunk, limitedBy: d.endIndex) ?? d.endIndex
        lines.append(d[i..<j].base64EncodedString())
        i = j
    }
    if lines.isEmpty { return pad + "<data>\n" + pad + "</data>" }
    return pad + "<data>\n" + lines.map { pad + $0 }.joined(separator: "\n")
        + "\n" + pad + "</data>"
}

private func xmlEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        default: out.append(ch)
        }
    }
    return out
}

/// 从文件读 plist（用于 doctor 核对产物里的路径等只读场景）。
func readPlistDict(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        as? [String: Any]
}

// ─────────────────────────────────────────────── 任意 plist → 保序序列化

/// 把 `PropertyListSerialization` 解出来的 `Any` 树转成保序的 `PlistValue`。
///
/// 为什么需要这层：Dock 配置（`com.apple.dock`）读进来是 `[String: Any]`，
/// **Swift 字典不保序**，直接序列化写回去键顺序就乱了 —— 而 Python 的
/// `plistlib.dumps` 默认 `sort_keys=True`，输出是**排好序**的、完全确定。
/// 两边要做到逐字节一致，这边就必须同样按键排序（用码点序，见 pyLess）。
///
/// 转换不了时把**出问题的位置**写进 `badPath`：这种错一旦发生，人最需要知道的
/// 就是「哪个键」，光说「不支持的值类型」等于没说。
func plistValue(from any: Any, path: String = "", badPath: inout String?) -> PlistValue? {
    func fail(_ kind: String) -> PlistValue? {
        if badPath == nil { badPath = "\(path.isEmpty ? "(根)" : path) → \(kind)" }
        return nil
    }

    switch any {
    case let s as String:  return .string(s)
    case let n as NSNumber:
        // ⚠️ NSNumber 是 Swift 里最经典的坑：`as? Bool` 对 0/1 也会成功，
        // 而 plist 里这几种类型是**语义不同**的（`<true/>` vs `<integer>1`）。
        // PropertyListSerialization 给回来的一律是 NSNumber，所以要看它的
        // 底层类型：CFBoolean 才是真布尔，CFNumber 再用 IsFloatType 区分
        // `<integer>` 和 `<real>`（不能用「值带不带小数点」猜 —— 71.0 是 real，
        // 但它的 stringValue 未必带 ".0"）。
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        if CFNumberIsFloatType(n) { return .real(n.doubleValue) }
        return .integer(n.intValue)
    case let d as Data:    return .data(d)
    case let n as Int:     return .integer(n)
    case let d as Double:  return .real(d)
    case let b as Bool:    return .bool(b)
    case let a as [Any]:
        var out: [PlistValue] = []
        for (i, item) in a.enumerated() {
            guard let v = plistValue(from: item, path: "\(path)[\(i)]", badPath: &badPath)
            else { return nil }
            out.append(v)
        }
        return .array(out)
    case let o as [String: Any]:
        // plistlib 的 sort_keys 是**逐层**排序，嵌套字典也一样。
        let keys = o.keys.sorted { pyLess($0, $1) }
        var pairs: [(String, PlistValue)] = []
        for k in keys {
            guard let v = plistValue(from: o[k]!,
                                     path: path.isEmpty ? k : "\(path).\(k)",
                                     badPath: &badPath) else { return nil }
            pairs.append((k, v))
        }
        return .dict(pairs)
    default:
        // `Data` / `Date` 等类型这里**故意不兜底**。
        // 兜底成字符串会静默写出一份语义已经变了的 Dock 配置（比如 data 变成
        // base64 文本），用户点开 Dock 才发现不对。宁可当场报错。
        return fail(String(describing: type(of: any)))
    }
}

/// Dock 配置字典 → XML plist 字节。等价于 Python 的 `plistlib.dumps(pl)`。
func plistData(_ pl: [String: Any]) throws -> Data {
    var bad: String?
    guard let v = plistValue(from: pl, path: "", badPath: &bad) else {
        throw DgError("Dock 配置里有本实现不支持的值类型，拒绝写入以免写坏配置：\(bad ?? "未知位置")")
    }
    return v.xmlData()
}
