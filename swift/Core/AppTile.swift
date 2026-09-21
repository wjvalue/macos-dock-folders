// swift/Core/AppTile.swift
//
// Dock tile 的构造。对应 Python 的 bundle_id / bookmark_bytes / make_app_tile。
//
// Python 那边 `bookmark_bytes` 又是一段 JXA（它调不到 Foundation）；Swift 直接调。
// 迁移期这两处会各自产生一份 bookmark 数据，字节应该完全一致 —— 因为底层是同一个
// API、同样的 options。对照测试会盯住这一点。

import Foundation

/// 读 App 的 CFBundleIdentifier。
func bundleId(_ app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let pl = (try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil)) as? [String: Any] else { return nil }
    return pl["CFBundleIdentifier"] as? String
}

/// 生成 Dock tile 的 `book` 字段。
///
/// ⚠️ 返回的是**原始字节**，不是 base64 字符串 —— plist 里这个字段的类型是
/// `<data>`（实测真实 com.apple.dock 里有 20 处）。Python 那边同样是
/// `base64.b64decode(jxa 输出)` 之后再放进 tile，两者必须一致，
/// 否则写出来的 Dock 配置这个字段会从 data 变成 string，Dock 认不认另说，
/// 至少和原版就不是同一份东西了。
func bookmarkBytes(_ app: URL) -> Data? {
    try? app.bookmarkData(options: [],
                          includingResourceValuesForKeys: nil,
                          relativeTo: nil)
}

/// Python `urllib.parse.quote(s)` 的 safe 集合：`ALWAYS_SAFE`（ASCII 字母数字 + `_.-~`）
/// 加上默认的 `/`。
///
/// 不能图省事用 `CharacterSet.urlPathAllowed` —— 它包含的字符集和 Python 不一样
/// （比如它不转义 `:`，而 Python 会），写出来的 `_CFURLString` 就会和原版有出入。
///
/// 不加 `private`：DockSync 里造 folder tile 时也要用同一份 safe 集合，
/// 两处各写一份迟早会漂。
let pyQuoteSafe = CharacterSet(charactersIn:
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/")

/// 左侧 App 区的 App tile，字段结构照抄系统自己写的。
///
/// 返回 `[String: Any]` 而不是保序结构 —— 写进 Dock 配置时由 `plistData()` 统一
/// 按键排序（对齐 `plistlib.dumps(sort_keys=True)`），这里不用操心顺序。
func makeAppTile(_ app: URL, label: String) -> [String: Any] {
    let path = app.path

    // GUID = md5(路径) 的前 4 字节按**大端**读成整数，再去掉最高位（& 0x7FFFFFFF）
    var guid: UInt32 = 0
    for b in md5Prefix(path, 4) { guid = (guid << 8) | UInt32(b) }
    guid &= 0x7FFF_FFFF

    var fileData: [String: Any] = [:]
    let escaped = path.addingPercentEncoding(withAllowedCharacters: pyQuoteSafe) ?? path
    fileData["_CFURLString"] = "file://\(escaped)/"
    fileData["_CFURLStringType"] = 15

    var data: [String: Any] = [:]
    data["dock-extra"] = false
    data["file-data"] = fileData
    data["file-label"] = label
    data["file-type"] = 41
    data["is-beta"] = false
    if let bid = bundleId(app) { data["bundle-identifier"] = bid }
    if let book = bookmarkBytes(app) { data["book"] = book }

    return [
        "GUID": Int(guid),
        "tile-data": data,
        "tile-type": "file-tile",
    ]
}
