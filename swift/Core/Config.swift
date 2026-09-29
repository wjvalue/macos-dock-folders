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
///
/// ⚠️ 「文件存在但读不出/解析不了」必须响亮失败：静默按「无分组」继续的话，
/// 任何会 saveConfig 的命令（new / add / style / layout / del）都会把这份
/// **只是语法坏了、本可手工救回**的配置直接覆盖掉。（2026-09-29 修。）
/// 文件不存在 → 返回默认空配置（首次运行），保持原行为。
func loadConfig() -> JSONObject {
    for url in [CONFIG_PATH, FALLBACK_CONFIG_PATH] {
        if !FileManager.default.fileExists(atPath: url.path) { continue }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatal("配置文件读不出来（编码不是 UTF-8？）：\(url.path)")
        }
        guard case .object(let o)? = parseJSON(text) else {
            fatal("配置文件不是合法 JSON（手工改坏了？先修好它再跑）：\(url.path)")
        }
        return o
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

/// 写配置，失败当场终止。
///
/// 为什么必须有这个变体：配置落盘失败（权限、磁盘满）而命令照常报成功，
/// Dock 的状态和 groups.json 就此分叉 —— 下一轮操作又基于旧配置回写，
/// 用户看到的是「改了又自己变回去」。 Dock 状态已经跟着内存里的新配置走了，
/// 配置没落盘是最不该静默的一种失败。（2026-09-29 收敛：9 处 `try? saveConfig`。）
func saveConfigOrDie(_ cfg: JSONObject) {
    do {
        try saveConfig(cfg)
    } catch {
        fatal("写配置失败（\(CONFIG_PATH.path)）：\(error.localizedDescription)")
    }
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
