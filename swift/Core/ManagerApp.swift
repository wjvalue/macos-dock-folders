// swift/Core/ManagerApp.swift
//
// 构建管理窗口 App（全机唯一，不随分组变化）。
// 对应 Python 的 manager_binary / make_manager_icon / build_manager_app。
//
// 和 build_launcher_app 的差别：这是有 Dock 图标、能被双击的普通 App，
// 所以 Info.plist 不设 LSUIElement（NSPrincipalClass = NSApplication 那条
// 是 SwiftUI @main 出窗口的命门，也不能少）。

import Cocoa
import Foundation

let MANAGER_SRC = "manager/main.swift"

/// 管理窗口源码查找：仓库优先，缓存兜底（与 launcherSourceURL 同款逻辑，
/// 见那里的注释 —— 仓库被删/挪后 rebuild 不断）。
func managerSourceURL() -> URL {
    let repoSrc = SCRIPT_DIR.appendingPathComponent(MANAGER_SRC)
    if FileManager.default.fileExists(atPath: repoSrc.path) { return repoSrc }
    let cachedSrc = CACHE.appendingPathComponent(".manager.main.swift")
    if FileManager.default.fileExists(atPath: cachedSrc.path) { return cachedSrc }
    FileHandle.standardError.write(
        "找不到管理窗口源码：\(repoSrc.path)\n（仓库被移动或删除了？重跑一次 tools/install.command 可修复）\n"
        .data(using: .utf8)!)
    exit(1)
}

/// 编译管理窗口二进制。判据和 launcherBinary 一致：按源码内容摘要，
/// 不看 mtime —— codesign 会把签名写进可执行文件，mtime 判据必然失效。
func managerBinary(force: Bool = false) -> URL {
    let src = managerSourceURL()
    let cached = CACHE.appendingPathComponent(".manager.bin")
    let stamp = CACHE.appendingPathComponent(".manager.src-stamp")
    let digest = sha256Hex((try? Data(contentsOf: src)) ?? Data())

    if !force,
       FileManager.default.fileExists(atPath: cached.path),
       let old = try? String(contentsOf: stamp, encoding: .utf8),
       old.trimmingCharacters(in: .whitespacesAndNewlines) == digest {
        return cached
    }

    try? FileManager.default.createDirectory(at: CACHE, withIntermediateDirectories: true)
    let swiftc = which("swiftc") ?? "/usr/bin/swiftc"
    // -parse-as-library：SwiftUI 的 @main 不能和顶层代码共存，不加这个
    // 编译直接报「'main' attribute cannot be used in a module that contains
    // top-level code」。
    let r = run(swiftc, ["-swift-version", "5", "-parse-as-library", "-O",
                         "-o", cached.path, src.path,
                         "-framework", "SwiftUI", "-framework", "Cocoa"])
    if !r.ok {
        FileHandle.standardError.write("编译管理窗口失败：\n\(r.errText)\n".data(using: .utf8)!)
        exit(1)
    }
    run("/bin/chmod", ["+x", cached.path])
    try? digest.write(to: stamp, atomically: true, encoding: .utf8)
    return cached
}

/// 画管理窗口的 Dock 图标。
///
/// 为什么不复用分组的拼贴图：拼贴图表达的是「某个分组里有什么」，而管理窗口管的是
/// 全部分组 —— 拿其中一个分组的样子当门面会误导。这里画抽象版：graphite 底板 +
/// 2×2 格子，和分组图标同一套视觉语言，内容中性。
///
/// 右下那一格用强调色（其余白色），是为了在 Dock 里一眼和分组图标区分开 ——
/// 两者底色和圆角都一样，纯靠格子颜色分辨。
@discardableResult
func makeManagerIcon(out: URL) -> URL {
    let S = 1024
    guard let st = STYLES[DEFAULT_STYLE] else { return out }
    var canvas = panelBase(S: S, st: st)
    let inset = Int(Double(S) * ICON_INSET)
    let side = S - 2 * inset

    let pad = Int(Double(side) * st.pad)
    let gap = Int(Double(side) * st.gap)
    let cell = pilDiv(side - 2 * pad - gap, 2)
    for r in 0..<2 {
        for c in 0..<2 {
            let x = inset + pad + c * (cell + gap)
            let y = inset + pad + r * (cell + gap)
            let fill: RGBA = (r, c) == (1, 1) ? RGBA(55, 138, 221, 250)
                                              : RGBA(255, 255, 255, 234)
            // PIL rounded_rectangle 是闭区间（宽 = x1-x0+1）→ pilRect 宽高各 +1
            //
            // ⚠️ Y 必须镜像：grayMask 的 CG user 原点在左下，画在 user y 的形状
            // 落在缓冲区行 S-b..S-a-1（见 grayMask 注释）。格子是不对称形状
            // （右下是强调色），不镜像的话强调色会跑到右上 —— 实测 MAE 26/255。
            // 镜像公式：PIL 行区间 [y, y+cell-1] → user 起点 = S - y - cell。
            let yUser = S - y - cell
            let box = pilRect(x, yUser, x + cell - 1, yUser + cell - 1)
            let radius = Int(Double(cell) * 0.16)
            let m = grayMask(size: S) { ctx in
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.addPath(roundedRectPath(box, radius: CGFloat(radius)))
                ctx.fillPath()
            }
            canvas.blend(color: fill, mask: m)
        }
    }
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    writePNG(canvas, to: out.path)
    return out
}

/// 把刚构建好的管理窗口同步到 /Applications（那儿已经有一份我们的才动）。
///
/// **为什么需要这一步**（2026-10-03 用户实报「打开 app 看不到之前的配置」）：
/// `/Applications/DockGroup.app` 是**独立的一份副本**，装的时候拷过去的。它不会
/// 跟着引擎升级 —— 升级后用户双击的还是旧版，而旧版的落盘路径是编译期烧死的。
/// 本次改动把落盘目录从 `~/Dock Groups` 搬进 Application Support，旧副本于是去
/// 老地方找、找不到就**按首次运行建了个空配置**，看起来就像配置丢了。
///
/// 判据用**可执行文件字节**而不是版本号：manager 的 CFBundleVersion 是写死的
/// "1"，比不出新旧；字节一样就说明是同一份，一个字节都不动（保 mtime，
/// 免得 Dock / LaunchServices 白刷一遍图标）。
///
/// 三种情况一律不碰，返回 nil：
///   · 对照测试模式（`DOCKGROUP_DOCK_PLIST`）—— 测试绝不能写真实 /Applications；
///   · /Applications 里没有 —— 不主动创建（用户可能只想要数据目录里那份）；
///   · 那儿是个**别人的**同名 App（bundle id 不是我们的）—— 绝不覆盖。
func syncManagerAppToApplications(_ built: URL) -> String? {
    if dockPlistOverride != nil { return nil }
    // DOCKGROUP_HOME（对照测试隔离）也跳过：测试绝不写真实 /Applications。
    // build-app.sh 第 ③ 步跑在 DOCKGROUP_HOME 下，缺这道闸的话发版脚本会把
    // 构建机自己装的那份悄悄换掉。（2026-10-03 修；Python 版同款。）
    if let h = ProcessInfo.processInfo.environment["DOCKGROUP_HOME"], !h.isEmpty {
        return nil
    }
    let dest = URL(fileURLWithPath: "/Applications/DockGroup.app")
    let fm = FileManager.default
    guard fm.fileExists(atPath: dest.path) else { return nil }
    guard let d = try? Data(contentsOf: dest.appendingPathComponent("Contents/Info.plist")),
          let pl = (try? PropertyListSerialization.propertyList(
              from: d, options: [], format: nil)) as? [String: Any],
          (pl["CFBundleIdentifier"] as? String) == "local.dockgroup.manager" else { return nil }

    // 只允许装**管理窗口** bundle：带 DockGroupName / DockGroupFolder 的是分组
    // 启动器，装进 /Applications 就成了「双击弹出某个分组面板」的怪东西。
    // （2026-10-03 手工测试时把分组启动器拷进去过，加这道闸防复发。）
    if let b = try? Data(contentsOf: built.appendingPathComponent("Contents/Info.plist")),
       let bp = (try? PropertyListSerialization.propertyList(
           from: b, options: [], format: nil)) as? [String: Any],
       bp["DockGroupName"] != nil || bp["DockGroupFolder"] != nil {
        return "⚠️  拒绝把分组启动器装进 /Applications（只装管理窗口）"
    }
    let builtExe = built.appendingPathComponent("Contents/MacOS/DockGroupManager")
    let destExe = dest.appendingPathComponent("Contents/MacOS/DockGroupManager")
    if let a = try? Data(contentsOf: builtExe), let b = try? Data(contentsOf: destExe), a == b {
        return nil   // 同一份，不折腾
    }
    // 先拷进 /Applications 下的暂存目录再交换：直接「删旧的 → 拷新的」的话，
    // 拷贝阶段失败（磁盘满 / 权限）会把旧副本删掉而新的没装上，双击的连旧版
    // 都没有。暂存放同一个目录里，rename 是同卷原子操作（2026-10-03 修）。
    let staging = dest.deletingLastPathComponent()
        .appendingPathComponent(".DockGroup.app.staging-\(getpid())")
    do {
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.copyItem(at: built, to: staging)
    } catch {
        try? fm.removeItem(at: staging)
        // 失败要说出来：静默的话用户双击的还是旧版，又变成「配置看不见」。
        return "⚠️  没能更新 /Applications/DockGroup.app（\(error.localizedDescription)）"
            + "；/Applications 里的旧副本未动，跑一次 tools/install.command 可修复"
    }
    do {
        try fm.removeItem(at: dest)
        try fm.moveItem(at: staging, to: dest)
    } catch {
        try? fm.removeItem(at: staging)
        return "⚠️  没能更新 /Applications/DockGroup.app（\(error.localizedDescription)）"
            + "；旧副本可能已不在，跑一次 tools/install.command 可修复"
    }
    return "已更新 /Applications/DockGroup.app（双击的那个）"
}

/// 打包管理窗口 App：图标 + Swift 二进制 + Info.plist + 签名。
/// 结构镜像 buildLauncherApp；版本键是写死的（"0.1.0" / "1"），摘要只决定
/// 「要不要重建 bundle」，不进版本号。
@discardableResult
func buildManagerApp(force: Bool = false) -> URL {
    let binary = managerBinary(force: force)
    let app = APPS.appendingPathComponent("DockGroup.app")
    let exe = app.appendingPathComponent("Contents/MacOS/DockGroupManager")
    let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
    let info = app.appendingPathComponent("Contents/Info.plist")
    let fm = FileManager.default

    let iconPng = makeManagerIcon(out: CACHE.appendingPathComponent("manager-icon.png"))

    // ⚠️ 键必须**按字母序**：plistlib.dumps 默认 sort_keys=True（与
    // buildLauncherApp 同一条规矩）。NSPrincipalClass 没有它 SwiftUI 的 @main
    // 在 bundle 里起不来窗口。
    let plist: [(String, PlistValue)] = [
        ("CFBundleDisplayName", .string("DockGroup 设置")),
        ("CFBundleExecutable", .string("DockGroupManager")),
        ("CFBundleIconFile", .string("AppIcon")),
        ("CFBundleIdentifier", .string("local.dockgroup.manager")),
        ("CFBundleName", .string("DockGroup")),
        ("CFBundlePackageType", .string("APPL")),
        ("CFBundleShortVersionString", .string("0.1.0")),
        ("CFBundleVersion", .string("1")),
        // GUI 进程的 PATH 只有 /usr/bin:/bin，也没有 dg 短命令，
        // 只能靠 Info.plist 把引擎位置告诉它。
        ("DockGroupScript", .string(engineCommand())),
        ("LSMinimumSystemVersion", .string("12.0")),
        ("NSHighResolutionCapable", .bool(true)),
        ("NSPrincipalClass", .string("NSApplication")),
    ]

    // 摘要 = sha256(plist 字节 + 二进制 + 图标)：图标进摘要 —— 只改画图逻辑
    // 不重打包的话，Dock 里还是旧图标。
    var blob = PlistValue.dict(plist).xmlData()
    blob.append((try? Data(contentsOf: binary)) ?? Data())
    blob.append((try? Data(contentsOf: iconPng)) ?? Data())
    let digest = sha256Hex(blob)

    let stamp = CACHE.appendingPathComponent("manager.bundle-stamp")
    let stampOld = (try? String(contentsOf: stamp, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let needRebuild = force
        || !fm.fileExists(atPath: exe.path)
        || stampOld != digest

    if needRebuild {
        // 与 buildLauncherApp 同规则：这一段不许 try?，磁盘满 / 权限失败时
        // 静默产出坏 bundle 还当构建成功。（2026-09-29 改。）
        do {
            try fm.createDirectory(at: exe.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: icon.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: exe.path) {
                try fm.removeItem(at: exe)   // 首次构建时 exe 还不存在，跳过
            }
            try fm.copyItem(at: binary, to: exe)
        } catch {
            fatal("重建管理窗口 App 失败：\(error.localizedDescription)")
        }
        run("/bin/chmod", ["755", exe.path])
        do {
            try pngToIcns(iconPng, icon)
            try PlistValue.dict(plist).xmlData().write(to: info, options: .atomic)
        } catch let e as DgError {
            fatal(e.message)
        } catch {
            fatal("写管理窗口 Info.plist 失败：\(error.localizedDescription)")
        }

        // 同 buildLauncherApp：重签前清 FinderInfo，否则第二次构建起签名必失败。
        run("/usr/bin/xattr", ["-c", app.path])
        let codesign = which("codesign") ?? "/usr/bin/codesign"
        let cs = run(codesign, ["--force", "--sign", "-", app.path])
        if !cs.ok {
            FileHandle.standardError.write(
                "⚠️ DockGroup.app codesign 失败（退出码 \(cs.status)）：\n\(cs.errText)\n".data(using: .utf8)!)
        }
        // 签名失败不写戳：戳一写，下一轮构建会因摘要命中而跳过重签，
        // 坏签名的产物就被固定住了。（与 buildLauncherApp 同规则。）
        if cs.ok {
            try? digest.write(to: stamp, atomically: true, encoding: .utf8)
        }
        if fm.fileExists(atPath: LSREGISTER) {
            run(LSREGISTER, ["-f", app.path])
        }
        // IconServices 按 mtime 缓存图标 —— 原地改内容不改 mtime，Dock 一直旧图标
        let now = Date()
        for d in [app, app.appendingPathComponent("Contents"),
                  app.appendingPathComponent("Contents/Resources"), icon, exe] {
            try? fm.setAttributes([.modificationDate: now], ofItemAtPath: d.path)
        }
    }

    // 产物要能脱离「我这台机器」。清隔离放在签名之后是安全的 ——
    // 签名保护的是文件内容，xattr 不在保护范围内。
    if stripQuarantine(app) {
        print("  已清除「\(app.lastPathComponent)」继承来的隔离属性（否则首次打开会被 Gatekeeper 拦）")
    }
    if let note = syncManagerAppToApplications(app) { print("  " + note) }
    return app
}
