// swift/Core/JSON.swift
//
// 有序 JSON —— 为什么不用 JSONSerialization / JSONEncoder：
//
// groups.json 要进版本库、要给人看，格式必须和 Python 引擎**逐字节一致**：
//   · `json.dump(ensure_ascii=False, indent=2)` + 末尾换行
//   · 键顺序 = Python dict 的插入顺序（Python 3.7+ 保序）
// 而 JSONSerialization 返回的是无序字典，JSONEncoder 的 prettyPrinted 又是
// `"key" : value`（冒号前多一个空格）。manager/main.swift 里已经因为同样的原因
// 手写过一份，这里做成通用版给整个 Swift 实现复用。
//
// 解析也必须自己写 —— 用 JSONSerialization 解出来的字典会丢掉键顺序，
// 存回去就是另一个文件了。

import Foundation

// ─────────────────────────────────────────────── 值类型

indirect enum JSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// 保序 JSON 对象。
/// Swift 的 Dictionary 不保序，所以用数组存 + 线性查找 —— 配置只有几十个键，
/// 这点开销换「键顺序不漂」完全值得。
struct JSONObject {
    var pairs: [(String, JSONValue)] = []

    init() {}
    init(_ pairs: [(String, JSONValue)]) { self.pairs = pairs }

    subscript(key: String) -> JSONValue? {
        get { pairs.first { $0.0 == key }?.1 }
        set {
            if let idx = pairs.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { pairs[idx].1 = v } else { pairs.remove(at: idx) }
            } else if let v = newValue {
                pairs.append((key, v))
            }
        }
    }

    var keys: [String] { pairs.map(\.0) }
    var isEmpty: Bool { pairs.isEmpty }
    var count: Int { pairs.count }
    func has(_ key: String) -> Bool { pairs.contains { $0.0 == key } }
}

// ─────────────────────────────────────────────── 便捷访问

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let n): return n
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    var stringArray: [String]? { arrayValue?.compactMap { $0.stringValue } }
}

// ─────────────────────────────────────────────── 序列化

/// 和 manager/main.swift 里那份逐字一致，方便两边互相对照。
func jsonQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 {
                out += String(format: "\\u%04x", u.value)
            } else {
                out.unicodeScalars.append(u)   // ensure_ascii=False：非 ASCII 原样输出
            }
        }
    }
    return out + "\""
}

/// Python 的 float repr：整数值的浮点也带小数点（1.0 → "1.0"）。
func jsonNumberText(_ d: Double) -> String {
    if d.isFinite && d == d.rounded() && abs(d) < 1e16 {
        return String(format: "%.1f", d)
    }
    return String(d)
}

extension JSONValue {
    /// 对齐 Python `json.dump(indent=2, ensure_ascii=False)`。
    /// 空对象/空数组写成 `{}` / `[]`（Python 也是），不展开成多行。
    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .double(let d): return jsonNumberText(d)
        case .string(let s): return jsonQuote(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n"
                + a.map { inner + $0.serialized(indent: indent + 2) }.joined(separator: ",\n")
                + "\n" + pad + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            return "{\n"
                + o.pairs.map { inner + jsonQuote($0.0) + ": " + $0.1.serialized(indent: indent + 2) }
                    .joined(separator: ",\n")
                + "\n" + pad + "}"
        }
    }
}

// ─────────────────────────────────────────────── 解析（保序）

struct JSONParser {
    private let s: [Unicode.Scalar]
    private var i = 0

    init(_ text: String) { s = Array(text.unicodeScalars) }

    private var cur: Unicode.Scalar? { i < s.count ? s[i] : nil }

    private mutating func skipWS() {
        while let c = cur, c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
    }

    mutating func parse() -> JSONValue? {
        skipWS()
        let v = parseValue()
        skipWS()
        return v
    }

    private mutating func parseValue() -> JSONValue? {
        skipWS()
        guard let c = cur else { return nil }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { .string($0) }
        case "t": return parseLiteral("true", .bool(true))
        case "f": return parseLiteral("false", .bool(false))
        case "n": return parseLiteral("null", .null)
        default: return parseNumber()
        }
    }

    private mutating func parseLiteral(_ word: String, _ value: JSONValue) -> JSONValue? {
        for ch in word.unicodeScalars {
            guard cur == ch else { return nil }
            i += 1
        }
        return value
    }

    private mutating func parseObject() -> JSONValue? {
        guard cur == "{" else { return nil }
        i += 1
        var obj = JSONObject()
        skipWS()
        if cur == "}" { i += 1; return .object(obj) }
        while true {
            skipWS()
            guard let key = parseString() else { return nil }
            skipWS()
            guard cur == ":" else { return nil }
            i += 1
            guard let v = parseValue() else { return nil }
            obj[key] = v
            skipWS()
            if cur == "," { i += 1; continue }
            if cur == "}" { i += 1; return .object(obj) }
            return nil
        }
    }

    private mutating func parseArray() -> JSONValue? {
        guard cur == "[" else { return nil }
        i += 1
        var arr: [JSONValue] = []
        skipWS()
        if cur == "]" { i += 1; return .array(arr) }
        while true {
            guard let v = parseValue() else { return nil }
            arr.append(v)
            skipWS()
            if cur == "," { i += 1; continue }
            if cur == "]" { i += 1; return .array(arr) }
            return nil
        }
    }

    private mutating func parseString() -> String? {
        guard cur == "\"" else { return nil }
        i += 1
        var out = String.UnicodeScalarView()
        while let c = cur {
            if c == "\"" { i += 1; return String(out) }
            if c != "\\" { out.append(c); i += 1; continue }
            i += 1
            guard let e = cur else { return nil }
            i += 1
            switch e {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "b": out.append(Unicode.Scalar(0x08)!)
            case "f": out.append(Unicode.Scalar(0x0C)!)
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                guard let hi = readHex4() else { return nil }
                var v = UInt32(hi)
                // 代理对：\uD83D\uDE00 这种要合并成一个标量
                if v >= 0xD800 && v <= 0xDBFF && cur == "\\" {
                    let save = i
                    i += 1
                    if cur == "u" {
                        i += 1
                        if let lo = readHex4(), lo >= 0xDC00, lo <= 0xDFFF {
                            v = 0x10000 + (v - 0xD800) * 0x400 + (UInt32(lo) - 0xDC00)
                        } else { i = save }
                    } else { i = save }
                }
                if let sc = Unicode.Scalar(v) { out.append(sc) }
            default: return nil
            }
        }
        return nil
    }

    /// `Unicode.Scalar` 上没有 `hexDigitValue`（那属于 Character），只能自己判。
    private mutating func readHex4() -> UInt16? {
        var v: UInt16 = 0
        for _ in 0..<4 {
            guard let c = cur else { return nil }
            let n = c.value
            let d: UInt16
            if n >= 0x30 && n <= 0x39 { d = UInt16(n - 0x30) }          // 0-9
            else if n >= 0x61 && n <= 0x66 { d = UInt16(n - 0x61 + 10) } // a-f
            else if n >= 0x41 && n <= 0x46 { d = UInt16(n - 0x41 + 10) } // A-F
            else { return nil }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = i
        var isFloat = false
        while let c = cur {
            if c == "-" || c == "+" || (c.value >= 0x30 && c.value <= 0x39) { i += 1 }
            else if c == "." || c == "e" || c == "E" { isFloat = true; i += 1 }
            else { break }
        }
        guard i > start else { return nil }
        let text = String(String.UnicodeScalarView(s[start..<i]))
        if !isFloat, let n = Int(text) { return .int(n) }
        if let d = Double(text) { return .double(d) }
        return nil
    }
}

func parseJSON(_ text: String) -> JSONValue? {
    var p = JSONParser(text)
    return p.parse()
}
