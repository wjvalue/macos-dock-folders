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

/// 生成 Dock tile 的 `book` 字段（base64 的 bookmark）。
/// JXA 传的 options 是 0，所以这里也是空 options。
func bookmarkBytes(_ app: URL) -> String? {
    do {
        let data = try app.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        return data.base64EncodedString()
    } catch {
        return nil
    }
}

/// Python `urllib.parse.quote(s)` 的 safe 集合：`ALWAYS_SAFE`（ASCII 字母数字 + `_.-~`）
/// 加上默认的 `/`。
///
/// ⚠️ 不能图省事用 `CharacterSet.urlPathAllowed` —— 它包含的字符集和 Python 不一样
/// （比如它不转义 `:`，而 Python 会），写出来的 `_CFURLString` 就会和原版有出入。
private let pyQuoteSafe = CharacterSet(charactersIn:
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/")

/// 左侧 App 区的 App tile，字段结构照抄系统自己写的。
func makeAppTile(_ app: URL, label: String) -> JSONObject {
    let path = app.path

    // GUID = md5(路径) 的前 4 字节按**大端**读成整数，再去掉最高位（& 0x7FFFFFFF）
    var guid: UInt32 = 0
    for b in md5Prefix(path, 4) { guid = (guid << 8) | UInt32(b) }
    guid &= 0x7FFF_FFFF

    var fileData = JSONObject()
    let escaped = path.addingPercentEncoding(withAllowedCharacters: pyQuoteSafe) ?? path
    fileData["_CFURLString"] = .string("file://\(escaped)/")
    fileData["_CFURLStringType"] = .int(15)

    var data = JSONObject()
    data["dock-extra"] = .bool(false)
    data["file-data"] = .object(fileData)
    data["file-label"] = .string(label)
    data["file-type"] = .int(41)
    data["is-beta"] = .bool(false)
    if let bid = bundleId(app) { data["bundle-identifier"] = .string(bid) }
    if let book = bookmarkBytes(app) { data["book"] = .string(book) }

    var tile = JSONObject()
    tile["GUID"] = .int(Int(guid))
    tile["tile-data"] = .object(data)
    tile["tile-type"] = .string("file-tile")
    return tile
}
