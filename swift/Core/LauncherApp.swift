// swift/Core/LauncherApp.swift
//
// 构建分组启动器 .app。对应 Python 的 launcher_binary / build_launcher_app。
//
// 这是整个工具最核心的一步：拼贴图标 + Swift 二进制 + Info.plist + 签名，
// 产出一个能放进 Dock 的 App。

import Foundation

let LSREGISTER = "/System/Library/Frameworks/CoreServices.framework"
    + "/Frameworks/LaunchServices.framework/Support/lsregister"

/// 启动器源码查找：仓库优先，缓存兜底。
///
/// 兜底是给「仓库被删/挪」的场景：install.command 预编译安装时会把 main.swift
/// 副本放进缓存（内容与源码摘要戳同源），仓库不在场时摘要照样命中缓存，
/// rebuild 不需要仓库存在。两边都找不到才报错。
func launcherSourceURL() -> URL {
    let repoSrc = SCRIPT_DIR.appendingPathComponent("launcher/main.swift")
    if FileManager.default.fileExists(atPath: repoSrc.path) { return repoSrc }
    let cachedSrc = CACHE.appendingPathComponent(".launcher.main.swift")
    if FileManager.default.fileExists(atPath: cachedSrc.path) { return cachedSrc }
    FileHandle.standardError.write(
        "找不到启动器源码：\(repoSrc.path)\n（仓库被移动或删除了？重跑一次 tools/install.command 可修复）\n"
        .data(using: .utf8)!)
    exit(1)
}

/// 编译启动器二进制 —— **所有分组共用同一份**。
///
/// 判据用 main.swift 的**内容摘要**，不能用 mtime：`codesign --force --sign -`
/// 会把签名写进 Mach-O（__LINKEDIT），改动可执行文件本身，于是它的 mtime 永远比
/// 源码新 —— `src.mtime > exe.mtime` 在第一次签名之后就永久失效。后果是改完
/// main.swift 跑 rebuild 不会重编译，Dock 上点开还是旧面板，而 rebuild 照样
/// 打印「已刷新」。（2026-09-20 踩过：UI 改动「没生效」，查了半天怀疑材质和圆角，
/// 实际是二进制压根没换。）
///
/// 启动器需要的全部信息（分组名、文件夹、材质、脚本路径）都写在 Info.plist 里，
/// 二进制与分组无关 —— 一份编译产物给所有分组用，rebuild 少编译 N-1 次。
func launcherBinary(force: Bool = false) -> URL {
    let src = launcherSourceURL()
    let cached = CACHE.appendingPathComponent(".launcher.bin")
    let stamp = CACHE.appendingPathComponent(".launcher.src-stamp")
    let digest = sha256Hex((try? Data(contentsOf: src)) ?? Data())

    if !force,
       FileManager.default.fileExists(atPath: cached.path),
       let old = try? String(contentsOf: stamp, encoding: .utf8),
       old.trimmingCharacters(in: .whitespacesAndNewlines) == digest {
        return cached
    }

    try? FileManager.default.createDirectory(at: CACHE, withIntermediateDirectories: true)
    let swiftc = which("swiftc") ?? "/usr/bin/swiftc"
    let r = run(swiftc, ["-swift-version", "5", "-O", "-o", cached.path,
                         src.path, "-framework", "Cocoa"])
    if !r.ok {
        FileHandle.standardError.write("编译启动器失败：\n\(r.errText)\n".data(using: .utf8)!)
        exit(1)
    }
    run("/bin/chmod", ["+x", cached.path])
    try? digest.write(to: stamp, atomically: true, encoding: .utf8)
    return cached
}

/// 构建启动器 App：拼贴图标 + Swift 二进制 + Info.plist。
///
/// 内容运行时从分组文件夹现读，所以往文件夹里加/删 App 只需重建图标，不必重编译。
/// 返回 (app 路径, 有效清单, 缺失清单)。
@discardableResult
func buildLauncherApp(_ g: JSONObject, style: String = DEFAULT_STYLE, force: Bool = false,
                      material: String = DEFAULT_MATERIAL, layout: String = DEFAULT_LAYOUT,
                      seed: Bool? = nil) throws
    -> (app: URL, ok: [(name: String, target: URL, isAlias: Bool)], missing: [String]) {
    let name = g.name
    let folder = BASE.appendingPathComponent(name)
    let (_, mosaic, ok, missing) = try buildGroup(g, style: style, seed: seed)

    let binary = launcherBinary(force: force)
    let app = APPS.appendingPathComponent("\(name).app")
    let exe = app.appendingPathComponent("Contents/MacOS/DockGroupLauncher")
    let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
    let info = app.appendingPathComponent("Contents/Info.plist")

    // bundle id = "local.dockgroup.app." + md5(分组名)[:5 字节的 hex]（= 10 个字符）
    let idHash = md5Prefix(name, 5).map { String(format: "%02x", $0) }.joined()

    // ⚠️ 键必须**按字母序**排列：Python 的 plistlib 默认 sort_keys=True，而下面的
    // 内容摘要就是把这份 plist 序列化后算的 —— 顺序不一样摘要就不一样，于是
    // CFBundleVersion 每次都变、每次 rebuild 都白刷一遍 Dock 图标。
    //
    // 一次构造好，别用「先少两项、再 insert(at:) 补回去」—— 那样索引一数错，
    // 键就跑到 DockGroupFolder 后面去了（这里踩过：at: 8 应该是 at: 7）。
    var core: [(String, PlistValue)] = [
        ("CFBundleDisplayName", .string(name)),
        ("CFBundleDocumentTypes", .array([
            .dict([
                ("CFBundleTypeName", .string("Application")),
                ("CFBundleTypeRole", .string("Viewer")),
                ("LSHandlerRank", .string("Alternate")),
                ("LSItemContentTypes", .array([
                    .string("com.apple.application"),
                    .string("com.apple.application-bundle"),
                ])),
            ]),
        ])),
        ("CFBundleExecutable", .string("DockGroupLauncher")),
        ("CFBundleIconFile", .string("AppIcon")),
        ("CFBundleIdentifier", .string("\(BUNDLE_PREFIX).\(idHash)")),
        ("CFBundleName", .string(name)),
        ("CFBundlePackageType", .string("APPL")),
        ("CFBundleShortVersionString", .string("1.0")),   // 占位，下面按摘要重写
        ("DockGroupFolder", .string(folder.path)),
        ("DockGroupLayout", .string(layout)),
        ("DockGroupLogDir", .string(CACHE.path)),
        ("DockGroupMaterial", .string(material)),
        ("DockGroupName", .string(name)),
        // 启动器收到拖放后要回调引擎；GUI 进程的 PATH 只有 /usr/bin:/bin，
        // 不能指望 dg 在 PATH 里，直接把绝对路径塞进去。
        ("DockGroupScript", .string(engineCommand())),
        ("LSMinimumSystemVersion", .string("12.0")),
        ("LSUIElement", .bool(true)),
        ("NSHighResolutionCapable", .bool(true)),
    ]

    // 摘要 = sha256(去掉 CFBundleVersion 的 plist 字节 + 图标 + 二进制)。
    //
    // 二进制也进摘要：main.swift 一改摘要就变，于是必然重写 exe 并重新签名 ——
    // 否则会出现「源码变了、戳没变」，拷贝那一步被跳过，App 里还是旧二进制。
    let withoutVersion = core.filter { $0.0 != "CFBundleVersion" }
    var blob = PlistValue.dict(withoutVersion).xmlData()
    blob.append((try? Data(contentsOf: mosaic)) ?? Data())
    blob.append((try? Data(contentsOf: binary)) ?? Data())
    let digest = sha256Hex(blob)

    // 让版本号跟着内容走：图标/二进制一变版本号就变，Dock 才会刷新图标缓存。
    // （bundle 路径和版本号都不变时，IconServices 会一直用旧图标缓存。）
    core.append(("CFBundleVersion", .string(String(digest.prefix(8)))))
    for i in core.indices where core[i].0 == "CFBundleShortVersionString" {
        core[i].1 = .string("1.0." + String(digest.prefix(6)))
    }
    // 补进去的 CFBundleVersion 要落在字母序的位置上，不能直接 append 到末尾
    core.sort { pyLess($0.0, $1.0) }

    let stamp = CACHE.appendingPathComponent("\(name).bundle-stamp")
    let stampOld = (try? String(contentsOf: stamp, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let needRebuild = force
        || !FileManager.default.fileExists(atPath: exe.path)
        || stampOld != digest

    guard needRebuild else {
        return (app, ok, missing)
    }

    // 覆盖 exe 必须在签名之前：改了 bundle 内容不重签，macOS 会拒绝启动。
    try? FileManager.default.createDirectory(at: exe.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: icon.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: exe)
    try? FileManager.default.copyItem(at: binary, to: exe)
    run("/bin/chmod", ["755", exe.path])
    pngToIcns(mosaic, icon)
    try? PlistValue.dict(core).xmlData().write(to: info, options: .atomic)

    let codesign = which("codesign") ?? "/usr/bin/codesign"
    run(codesign, ["--force", "--sign", "-", app.path])

    if FileManager.default.fileExists(atPath: LSREGISTER) {
        run(LSREGISTER, ["-f", app.path])
    }

    // 关键：IconServices 按 bundle 的 mtime 缓存图标。原地改内容而不改 mtime，
    // Dock 会一直显示旧图标（实测踩过）。
    let now = Date()
    for d in [app, app.appendingPathComponent("Contents"),
              app.appendingPathComponent("Contents/Resources"), icon] {
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: d.path)
    }

    try? digest.write(to: stamp, atomically: true, encoding: .utf8)

    // 产物要能脱离「我这台机器」。清隔离属性放在签名之后是安全的 ——
    // 签名保护的是文件内容，xattr 不在保护范围内。
    if stripQuarantine(app) {
        print("  已清除「\(app.lastPathComponent)」继承来的隔离属性")
    }
    return (app, ok, missing)
}
