// swift/Core/Config.swift
//
// groups.json 的读写。对齐 Python 的 `load_config` / `save_config`：
//   · 按 CONFIG_PATH → 仓库里的 groups.json 顺序找，都没有就返回 `{"groups": []}`
//     （注意：这时候**没有** style / material / layout 键，Python 也是这样）
//   · 写盘 = `json.dump(ensure_ascii=False, indent=2)` + 末尾换行
//
// 配置用 JSONObject 存而不是强类型 struct，是为了**原样保留未知键和键顺序** ——
// Python 那边就是拿 dict 改完再 dump，多余的键不会丢、顺序也不变。
// 用 struct 的话，一份带额外键的配置被读进来再写出去就变形了。

import Foundation

// 与 scripts/dockgroup.py 第 161 / 168 / 208 行一致。
// （核对命令：grep -n "DEFAULT_STYLE\|DEFAULT_MATERIAL\|DEFAULT_LAYOUT" scripts/dockgroup.py）
let DEFAULT_STYLE = "graphite"
let DEFAULT_MATERIAL = "hud"
let DEFAULT_LAYOUT = "row"

/// 读配置。
func loadConfig() -> JSONObject {
    for url in [CONFIG_PATH, FALLBACK_CONFIG_PATH] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if case .object(let o)? = parseJSON(text) { return o }
    }
    return JSONObject([("groups", .array([]))])
}

/// 写配置。格式必须和 Python 的 `json.dump(..., indent=2)` + 末尾换行逐字节一致。
func saveConfig(_ cfg: JSONObject) throws {
    try FileManager.default.createDirectory(at: CONFIG_PATH.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try (JSONValue.object(cfg).serialized() + "\n")
        .write(to: CONFIG_PATH, atomically: true, encoding: .utf8)
}

// ─────────────────────────────────────────────── 访问器

extension JSONObject {
    /// 分组数组。用 computed property 包一层，读写都走它，
    /// 免得每处都写 `.arrayValue.compactMap { $0.objectValue }`。
    var groups: [JSONObject] {
        get { (self["groups"]?.arrayValue ?? []).compactMap { $0.objectValue } }
        set { self["groups"] = .array(newValue.map { .object($0) }) }
    }

    func group(named name: String) -> JSONObject? {
        groups.first { $0["name"]?.stringValue == name }
    }

    var style: String { self["style"]?.stringValue ?? DEFAULT_STYLE }
    var material: String { self["material"]?.stringValue ?? DEFAULT_MATERIAL }
    var layout: String { self["layout"]?.stringValue ?? DEFAULT_LAYOUT }
}

extension JSONObject {
    var name: String { self["name"]?.stringValue ?? "" }
    var enabled: Bool { self["enabled"]?.boolValue ?? true }
    var placement: String { self["placement"]?.stringValue ?? "left" }
    var apps: [String] { self["apps"]?.stringArray ?? [] }

    /// 分组级外观覆盖（优先级高于全局）。
    var styleOverride: String? { self["style"]?.stringValue }
    var materialOverride: String? { self["material"]?.stringValue }
    var layoutOverride: String? { self["layout"]?.stringValue }
}

// ─────────────────────────────────────────────── 分组外观解析
//
// 分组级覆盖优先于全局 —— 这条是 2026-09-20 修过的坑：
// 「改了配置不生效」的三大成因之一就是分组覆盖，排查了很久。
// 对应 Python 的 group_material() / group_layout()。

func groupStyle(_ cfg: JSONObject, _ g: JSONObject) -> String {
    g.styleOverride ?? cfg.style
}

func groupMaterial(_ cfg: JSONObject, _ g: JSONObject) -> String {
    g.materialOverride ?? cfg.material
}

func groupLayout(_ cfg: JSONObject, _ g: JSONObject) -> String {
    g.layoutOverride ?? cfg.layout
}
