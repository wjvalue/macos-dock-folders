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
            return pad + "<real>\(d)</real>"
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
