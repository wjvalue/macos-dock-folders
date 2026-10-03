// swift/Bootstrap/main.swift
//
// DockGroup.app 的可执行入口 —— 「下载即用」的关键。
//
// 这个二进制**只做一件事**：把 .app 载荷里自带的东西装到用户机器上，
// 然后打开管理窗口。它不是 dg，也永远不会出现在 PATH 里：
//
//   载荷（Contents/Resources/repo/，与 prebuilt.zip 同构）：
//     prebuilt/dg                 universal 引擎二进制
//     prebuilt/DockGroup*.bin     启动器 / 管理窗口预编译二进制
//     scripts/                    引擎源码根（launcher/manager 源码 + dockgroup.py）
//
//   安装动作（与 tools/install.command 预编译分支一一对应）：
//     ① scripts/ + prebuilt/ → ~/Library/Application Support/DockGroup/（安装根）；
//        旧 ~/Dock Groups → 安装根/data/（迁移，之后 home 目录不再留东西）
//        （安装根固定在这里，用户把 .app 挪走/删掉都不影响引擎找源码；
//         落盘数据也收在同一个 Library 目录下，符合 macOS 惯例）
//     ② prebuilt/dg → ~/.local/bin/dg，仓库标记指向 ①
//     ③ 启动器/管理窗口二进制 + 源码摘要戳 → 安装根/data/.cache/
//        （安装根在 Library 下，cacheDir 与引擎 CACHE 同一口径）
//        （戳用 CryptoKit 现算 —— 算法与引擎 Hash.swift 一致：
//         sha256 小写 hex。命中缓存 = 用户机器不需要 CLT）
//     ④ xattr -cr 拷贝产物（下载的 zip 解出来全带 quarantine 标记，
//        不清的话拷出去的 dg 第一次被 spawn 会被 Gatekeeper 拦）
//     ⑤ `dg gui` 打开管理窗口
//
// 可重入：每次双击都重跑 ①-④（幂等，顺带就是升级），已装过的机器秒过。
//
// 测试怎么不弄脏真机：home 显式读 $HOME 环境变量（launchd 登录态下就是真实
// 家目录；注意 Foundation 的 homeDirectoryForCurrentUser 读的是 passwd 条目，
// **不**跟随 $HOME —— 已实测）。子进程 dg 显式传 DOCKGROUP_REPO /
// DOCKGROUP_HOME，与 ①③ 写到的地方严格一致；DOCKGROUP_BOOTSTRAP_NO_OPEN=1
// 时改传 --no-open（沙箱 / CI 用）。

import CryptoKit
import Foundation

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment

func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

/// 逐字节 sha256，小写 hex —— 必须与引擎 Hash.swift 的 sha256Hex 一致。
/// 读不出源码必须 fail 而不是拿空数据凑数：对空数据求的哈希写进摘要戳后
/// 与引擎实算永远不相等，缓存永不命中，用户的「免 CLT」卖点静默失效。
/// （2026-09-29 修。）
func sha256HexFile(_ url: URL) -> String {
    guard let d = try? Data(contentsOf: url), !d.isEmpty else {
        fail("读不到源码，无法计算摘要戳：\(url.path)")
    }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

@discardableResult
func run(_ path: String, _ args: [String], extraEnv: [String: String] = [:]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var e = env
    for (k, v) in extraEnv { e[k] = v }
    p.environment = e
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    do { try p.run() } catch { out("⚠️  启动 \(path) 失败：\(error.localizedDescription)") ; return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func copyOverwriting(_ src: URL, _ dst: URL) throws {
    // removeItem 不许 try?：删不掉（目标被占用/权限）却接着 copy，报出来的是
    // 「文件已存在」这种看不出真因的错误。（2026-09-29 改。）
    if fm.fileExists(atPath: dst.path) {
        try fm.removeItem(at: dst)
    }
    try fm.copyItem(at: src, to: dst)
}

// ── home 与载荷 ────────────────────────────────────────────────

let home: URL = {
    if let h = env["HOME"], !h.isEmpty { return URL(fileURLWithPath: h).standardizedFileURL }
    return fm.homeDirectoryForCurrentUser
}()

// 载荷必须随 .app 一起走：单独运行这个二进制时资源目录里没有 repo/，
// 给出能看懂的报错，而不是在半路拷出个残缺安装。
guard let res = Bundle.main.resourceURL else {
    fail("不在 .app bundle 里运行，找不到载荷。请双击 DockGroup.app。")
}
let payloadRepo = res.appendingPathComponent("repo", isDirectory: true)
guard fm.fileExists(atPath: payloadRepo.appendingPathComponent("prebuilt/dg").path) else {
    fail("载荷缺失（\(payloadRepo.path) 下没有 prebuilt/dg）。请使用完整的 DockGroup.app。")
}

// ── ① 安装根 ──────────────────────────────────────────────────

let installRoot = home.appendingPathComponent("Library/Application Support/DockGroup")
do {
    try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
    for item in ["scripts", "prebuilt"] {
        try copyOverwriting(payloadRepo.appendingPathComponent(item),
                            installRoot.appendingPathComponent(item))
    }
} catch {
    fail("写安装根失败（\(installRoot.path)）：\(error.localizedDescription)")
}

// ── ①b 旧数据迁移：~/Dock Groups → 安装根/data/ ───────────────
// v1.4.0 起 home 目录不再留东西。只在新 data/ 还不存在时搬；新目录已有
// 内容说明迁过（或用户是全新安装），这时旧目录还在就是异常状态，只警告。
// 搬完后的重建 + Dock 同步由第 ⑤ 步调起的 dg gui 自动完成（引擎启动时
// migrateLegacyDataIfNeeded 已无事可做 —— 目录已经在新位置）。

let dataDir = installRoot.appendingPathComponent("data")
let cacheDir = dataDir.appendingPathComponent(".cache")
let legacyBase = home.appendingPathComponent("Dock Groups")
let migratedDataDir = dataDir
// 旧版管理窗口是独立进程、落盘路径编译期烧死：不结束它，迁移完它一保存
// 又把 ~/Dock Groups 建回来（pitfalls 27.3；引擎迁移与 install.command 同款）。
// 没有匹配进程时 pkill 返回非零，随它去。
run("/usr/bin/pkill", ["-x", "DockGroupManager"])
do {
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: legacyBase.path, isDirectory: &isDir), isDir.boolValue {
        if fm.fileExists(atPath: migratedDataDir.path) {
            out("⚠️  旧目录 ~/Dock Groups 还在，但新目录已有内容，没有自动迁移。")
            out("   确认数据无误后可手动删除 ~/Dock Groups。")
        } else {
            try fm.moveItem(at: legacyBase, to: migratedDataDir)
            out("已迁移：~/Dock Groups → \(migratedDataDir.path)")
        }
    }
} catch {
    fail("迁移旧数据失败（~/Dock Groups）：\(error.localizedDescription)")
}

// ── ② dg 短命令 + 仓库标记 ────────────────────────────────────

let localBin = home.appendingPathComponent(".local/bin")
try? fm.createDirectory(at: localBin, withIntermediateDirectories: true)
let dgDest = localBin.appendingPathComponent("dg")

// 旧 Python shim 留个备份（install.command 的同款礼节；判断看首行 shebang
// 加内容特征，避免把真二进制误判成 shim）。
if let fh = FileHandle(forReadingAtPath: dgDest.path),
   let head = String(data: fh.readData(ofLength: 200), encoding: .utf8),
   head.hasPrefix("#!"), head.contains("dockgroup.py") {
    fh.closeFile()
    let bak = localBin.appendingPathComponent("dg.python-shim.bak")
    try? fm.removeItem(at: bak)
    try? fm.moveItem(at: dgDest, to: bak)
    out("   旧的 Python shim 已备份为 dg.python-shim.bak")
}

do {
    try copyOverwriting(installRoot.appendingPathComponent("prebuilt/dg"), dgDest)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dgDest.path)
    let marker = localBin.appendingPathComponent(".dg-repo-root")
    try installRoot.path.write(to: marker, atomically: true, encoding: .utf8)
} catch {
    fail("安装 dg 失败（\(dgDest.path)）：\(error.localizedDescription)")
}

// ── ③ 种缓存（二进制 + 源码 + 摘要戳）─────────────────────────

do {
    try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let pairs: [(String, String)] = [
        ("prebuilt/DockGroupLauncher.bin", ".launcher.bin"),
        ("prebuilt/DockGroupManager.bin", ".manager.bin"),
        ("scripts/launcher/main.swift", ".launcher.main.swift"),
        ("scripts/manager/main.swift", ".manager.main.swift"),
    ]
    for (src, dst) in pairs {
        try copyOverwriting(installRoot.appendingPathComponent(src),
                            cacheDir.appendingPathComponent(dst))
    }
    // 摘要戳 = 引擎里 managerSourceURL / launcherSourceURL 命中**安装根**里
    // 那份源码时算出的 digest —— 内容相同所以必须相等，缓存才会命中。
    for (src, stamp) in [("scripts/launcher/main.swift", ".launcher.src-stamp"),
                         ("scripts/manager/main.swift", ".manager.src-stamp")] {
        let hex = sha256HexFile(installRoot.appendingPathComponent(src))
        try hex.write(to: cacheDir.appendingPathComponent(stamp), atomically: true,
                      encoding: .utf8)
    }
} catch {
    fail("预置缓存失败（\(cacheDir.path)）：\(error.localizedDescription)")
}

// ── ④ 清隔离（只清拷贝产物，.app 本身由用户首开时处理）────────

// xattr 失败要吭声：静默过去的话，用户第一次 spawn dg 才被 Gatekeeper 拦，
// 看到的只有一句笼统的「启动失败」。（2026-09-29 加。）
for target in [installRoot, dgDest, cacheDir] {
    let rc = run("/usr/bin/xattr", ["-cr", target.path])
    if rc != 0 {
        out("⚠️  隔离属性清理失败（xattr -cr \(target.path) 退出码 \(rc)），"
            + "首次运行可能被 Gatekeeper 拦截")
    }
}

// ── ⑤ 打开管理窗口 ────────────────────────────────────────────

let noOpen = env["DOCKGROUP_BOOTSTRAP_NO_OPEN"] != nil
var guiArgs = ["gui"]
if noOpen { guiArgs.append("--no-open") }

out("DockGroup 已就绪（引擎：\(dgDest.path)）")
let rc = run(dgDest.path, guiArgs, extraEnv: [
    "DOCKGROUP_REPO": installRoot.path,
    "DOCKGROUP_HOME": dataDir.path,
])
exit(rc)
