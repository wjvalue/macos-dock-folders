// swift/Core/Paths.swift
//
// 路径常量。照抄 scripts/dockgroup.py 顶部那组定义，不凭记忆改 ——
// 两套实现必须指向**同一个** BASE，否则对照测试失去意义。

import Foundation

let HOME = FileManager.default.homeDirectoryForCurrentUser

/// 某个目录是不是一棵**可用**的源码树（有引擎脚本才算）。
/// 只用来判「编译期烧的路径在本机还成不成立」，别拿它当别处的守卫。
func looksLikeSourceTree(_ url: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: url.appendingPathComponent("scripts/dockgroup.py").path)
}

/// 仓库根目录。解析顺序：
///   1. 环境变量 `DOCKGROUP_REPO`（测试 / 手动覆盖）
///   2. 编译期烧入的 `BUILD_REPO_ROOT`（见 swift/build.sh 生成的 BuildInfo.swift）
///      —— **但只在它本机真的存在、且是一棵完整源码树时**才认它
///   3. 标记文件 `~/.local/bin/.dg-repo-root`（安装器写入，指向安装根）
///
/// 为什么 2 要排在 3 前面（2026-10-03 修）：分发出去的二进制里烧的是**构建机**
/// 的路径，在用户机上不存在，自然落到 3 —— 原设计意图正是如此。但旧代码让标记
/// 文件**无条件**优先，于是本机开发时引擎一直去读安装根里那份**安装时拷的旧
/// 源码**：改了仓库源码、重编了 dg，manager 却是拿旧源码编出来的（用户实报
/// 「打开 app 看不到配置」就是这么来的）。让「存在的源码树」优先，两种场景都对：
/// 用户机上编译期路径不存在 → 走标记；开发机上源码树就在手边 → 用它。
let REPO_ROOT: URL = {
    let env = ProcessInfo.processInfo.environment
    if let r = env["DOCKGROUP_REPO"], !r.isEmpty {
        return URL(fileURLWithPath: r).standardizedFileURL
    }
    let built = URL(fileURLWithPath: BUILD_REPO_ROOT).standardizedFileURL
    if looksLikeSourceTree(built) { return built }
    let marker = HOME.appendingPathComponent(".local/bin/.dg-repo-root")
    if let s = try? String(contentsOf: marker, encoding: .utf8) {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p).standardizedFileURL
        }
    }
    return built
}()
let SCRIPT_DIR = REPO_ROOT.appendingPathComponent("scripts")

/// 落盘目录。可用 `DOCKGROUP_HOME` 覆盖 —— 对照测试要靠它把两边隔离到同一处，
/// Python 版也是同款行为。
///
/// 默认位置（v1.4.0 起）：`~/Library/Application Support/DockGroup/data/` ——
/// home 目录不再留东西。旧版默认的 `~/Dock Groups` 由 migrateLegacyDataIfNeeded()
/// 一次性无损搬过来（见本文件末尾）。
let APP_SUPPORT = HOME.appendingPathComponent("Library/Application Support/DockGroup")
let BASE: URL = {
    if let h = ProcessInfo.processInfo.environment["DOCKGROUP_HOME"], !h.isEmpty {
        return URL(fileURLWithPath: h).standardizedFileURL
    }
    return APP_SUPPORT.appendingPathComponent("data")
}()

let CACHE = BASE.appendingPathComponent(".cache")
let BACKUP = BASE.appendingPathComponent(".backup")
/// 备份轮转上限：dockWrite 每次真实写入留一份，超过就删最旧的。
let BACKUP_KEEP = 20
let APPS = BASE.appendingPathComponent(".apps")
let CONFIG_PATH = BASE.appendingPathComponent("groups.json")

/// 仓库里的兜底配置（对应 Python 的 `SCRIPT_DIR / "groups.json"`）。
let FALLBACK_CONFIG_PATH = SCRIPT_DIR.appendingPathComponent("groups.json")

let DOCK_DOMAIN = "com.apple.dock"
let BUNDLE_PREFIX = "local.dockgroup.app"

/// 文件夹自定义图标的载体文件名，末尾是真实的 CR —— 别写成 "Icon"。
let ICON_ENTRY = "Icon\r"

/// 缓存里图标的边长上限。
let ICON_SRC_PX = 512

/// 生成 .app 的 Info.plist 里 DockGroupScript 该写的引擎入口。
///
/// 优先用户级的 dg 短命令（Swift 版二进制或它的 shim 都能被直接 exec），
/// 没有就退回仓库里的 dockgroup.py。这个路径跨引擎切换是**稳定**的：
/// install.command 把 ~/.local/bin/dg 从 Python shim 换成 Swift 二进制后，
/// 旧 .app 无需重建就会自动用上新引擎。与 Python 侧 `engine_command()`
/// 必须解析出**同一个路径**，对照测试比的就是这个。
func engineCommand() -> String {
    let dg = HOME.appendingPathComponent(".local/bin/dg")
    var isDir: ObjCBool = false
    if FileManager.default.isExecutableFile(atPath: dg.path),
       FileManager.default.fileExists(atPath: dg.path, isDirectory: &isDir),
       !isDir.boolValue {
        return dg.path
    }
    return SCRIPT_DIR.appendingPathComponent("dockgroup.py").path
}

// iOS 主屏文件夹的几何比例（相对文件夹边长）
let ICON_INSET = 0.02
let BG_RADIUS = 0.235

/// 拼贴图标（Dock 里的分组图标）专用留白：Apple 标准图标网格 824/1024。
/// 为什么和 ICON_INSET 分开：面板底板要「全覆盖」（96%）是面板自己的观感；
/// 而 Dock 图标在 2026-09-22 起走「自定义图标」通道被系统 1:1 渲染（不再被
/// 缩进白框），全覆盖反而比邻居图标大一圈 —— 按系统网格留白才和大家一样大。
let TILE_INSET = 0.098

// ─────────────────────────────────────────────── 旧版迁移（v1.4.0）

/// 旧版默认落盘目录（v1.4.0 之前是 `~/Dock Groups`）。
private let LEGACY_BASE = HOME.appendingPathComponent("Dock Groups")

/// 一次性迁移：旧 `~/Dock Groups` → 新 BASE。之后 home 目录不再留东西。
///
/// 只在「默认落盘」时跑：设了 `DOCKGROUP_HOME`（对照测试隔离）或
/// `DOCKGROUP_DOCK_PLIST`（测试替身）直接跳过 —— 测试绝不能碰真实数据。
/// 新 BASE 已存在说明迁过（安装器也会先搬），这时旧目录还在就是异常状态，
/// 只警告不动手（重跑安装器可再迁，见警告文案）。
func migrateLegacyDataIfNeeded() {
    let env = ProcessInfo.processInfo.environment
    // 口径与 BASE 的解析一致：**非空**才算设了（Python 侧真值判断同款）。
    // 空串按未设处理，否则两边对「设了没有」各说各话。（2026-10-03 修。）
    if let h = env["DOCKGROUP_HOME"], !h.isEmpty { return }
    if let p = env["DOCKGROUP_DOCK_PLIST"], !p.isEmpty { return }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: LEGACY_BASE.path, isDirectory: &isDir), isDir.boolValue else { return }

    // 先把**旧版管理窗口**结束掉。它是独立进程、落盘路径编译期烧死，会一边
    // 往旧位置写一边把空配置留在那儿 —— 用户升级后看到的「配置没了」正是它
    // 干的（2026-10-03 实报）。不杀的话我们这边刚迁完，它下一次保存又把
    // ~/Dock Groups 建回来。
    run("/usr/bin/pkill", ["-x", "DockGroupManager"])
    guard !fm.fileExists(atPath: BASE.path) else {
        // 数据早就在新位置了，旧目录还在 = 多半是**旧版 app 留下的空壳**
        // （它落盘路径烧死在旧位置，一保存就把目录建回来）。这时**没有**东西
        // 可迁 —— 早先的文案说「重跑 install.command 即可完成迁移」是错的，
        // 用户会反复重跑而目录始终在（2026-10-03 修）。讲清楚怎么自己确认。
        print("注：~/Dock Groups 还在，但数据已经在新位置了，没有可迁移的内容。")
        print("   它多半是旧版管理窗口留下的空壳（新版已结束它的进程）。")
        print("   确认无误后可删：先看一眼 ~/Dock Groups/groups.json，")
        print("   若只是个空模板（没有你的分组），rm -rf ~/Dock Groups 即可。")
        return
    }
    do {
        try fm.createDirectory(at: APP_SUPPORT, withIntermediateDirectories: true)
        try fm.moveItem(at: LEGACY_BASE, to: BASE)
    } catch {
        fatal("迁移旧数据失败（~/Dock Groups → \(BASE.path)）：\(error.localizedDescription)")
    }
    // 数据搬完，但 .apps 里的 DockGroupFolder 和 Dock tile 还指着旧路径 →
    // 重建全部、同步一次。refreshGroups 只重建不管位置，dockSync 负责把 tile
    // 按 label 原地换成新路径（「原地替换」，位置不动）。
    let cfg = loadConfig()
    let touched = refreshGroups(cfg, quiet: true)
    do {
        try dockSync(cfg, only: nil, prune: true, rebuilt: !touched.isEmpty)
    } catch let e as DgError {
        fatal(e.message)
    } catch {
        fatal("迁移后同步 Dock 失败：\(error)")
    }
    // watch agent 里的 WatchPaths / DOCKGROUP_HOME 还指旧位置 → 装过才重装。
    let agent = HOME.appendingPathComponent("Library/LaunchAgents/\(WATCH_LABEL).plist")
    if fm.fileExists(atPath: agent.path) {
        cmdWatchInstall(cfg, [])
    }
    print("已迁移：~/Dock Groups → \(BASE.path)（旧目录已移除），Dock 已同步。")
    print("home 目录不再留 dockgroup 的东西：分组文件夹改用管理窗口的「在 Finder 里打开」。")
}

// ─────────────────────────────────────────────── 引擎副本自愈（v1.4.0）

/// 把「安装根」里的引擎副本对齐到**正在运行的这个二进制**。
///
/// **为什么需要**（2026-10-03 用户实报「直接拖，它提示：没有分组 AI」）：
/// 引擎的副本散在四处，升级时没有任何一处负责把它们换新 ——
///   · `~/.local/bin/dg`            ← 管理窗口**转发命令**就是调它
///   · 安装根 `prebuilt/dg`          ← 自安装 app 的 bootstrap 拿它覆盖前者
///   · 安装根 `scripts/`             ← 引擎找源码的兜底（也是 .py 回退）
///   · `/Applications/DockGroup.app` ← 用户双击的那个（见 syncManagerAppToApplications）
///
/// 只换新 `/Applications` 那份不够：GUI 里点「加进分组」是转发给 `dg` 执行的，
/// 而那个 dg 还是旧版 → 它按**编译期烧死的旧路径**找配置 → 空配置 → 报
/// 「没有分组 X」。用户看到的是「app 明明认识我的分组，一拖就说没有」。
///
/// 判据用**字节**：一样就一个字节都不动（保 mtime / 权限，也避免每次启动都写盘）。
/// 对照测试模式（`DOCKGROUP_HOME` / `DOCKGROUP_DOCK_PLIST`）直接跳过 ——
/// 测试绝不能写用户的安装根。
func syncInstalledEngineCopies() {
    let env = ProcessInfo.processInfo.environment
    // 口径与 BASE 一致：非空才算设了（见 migrateLegacyDataIfNeeded 同款注释）。
    if let h = env["DOCKGROUP_HOME"], !h.isEmpty { return }
    if let p = env["DOCKGROUP_DOCK_PLIST"], !p.isEmpty { return }

    let fm = FileManager.default
    let selfURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    guard let selfData = try? Data(contentsOf: selfURL), !selfData.isEmpty else { return }

    // 两份「引擎副本」的候选位置。
    let installedProbe = HOME.appendingPathComponent(".local/bin/dg")
    let rootProbe = APP_SUPPORT.appendingPathComponent("prebuilt/dg")

    // 只在「自己就是从某个安装位置跑起来的」时自愈 —— 判据是**这个二进制本身**
    // 在不在它要去对齐的位置上，而不是「在不在仓库里」。
    //
    // 为什么不能拿 REPO_ROOT 当判据（2026-10-03 踩）：REPO_ROOT 在本机开发时会
    // 解析到**仓库**，而开发时跑的是 build/dg-swift —— 用它当守卫会让「已安装的
    // dg」也被误判成开发态而跳过自愈，正好漏掉要修的那个场景。反过来，真在仓库里
    // 跑 build/dg-swift 时，它既不等于 ~/.local/bin/dg 也不等于安装根那份，
    // 下面的逐项比较天然不会动任何东西。
    let iAmInstalled = (try? Data(contentsOf: installedProbe)).map { $0 == selfData } ?? false
    let iAmRootCopy = (try? Data(contentsOf: rootProbe)).map { $0 == selfData } ?? false
    guard iAmInstalled || iAmRootCopy else { return }

    func same(_ url: URL) -> Bool {
        (try? Data(contentsOf: url)).map { $0 == selfData } ?? false
    }
    func put(_ url: URL) {
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // .atomic：临时文件 + rename，写入中断不会留下半截二进制 ——
            // 自愈窗口内 GUI 转发命令撞上坏 dg 就起不来了。（2026-10-03 修。）
            try selfData.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            FileHandle.standardError.write(
                "⚠️  引擎副本自愈失败（\(url.path)）：\(error.localizedDescription)\n"
                .data(using: .utf8)!)
        }
    }

    // 只补**另一份**：正在运行的那份自己不用重写（写自己会失败/无意义）。
    if !iAmInstalled, !same(installedProbe) { put(installedProbe) }
    if !iAmRootCopy, !same(rootProbe) { put(rootProbe) }

    // Python 回退脚本也一起对齐（源码安装路径会用；预编译用户没有它也无所谓）。
    let repoPy = REPO_ROOT.appendingPathComponent("scripts/dockgroup.py")
    let rootPy = APP_SUPPORT.appendingPathComponent("scripts/dockgroup.py")
    if let want = try? Data(contentsOf: repoPy),
       (try? Data(contentsOf: rootPy)).map({ $0 == want }) != true {
        try? fm.createDirectory(at: rootPy.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? want.write(to: rootPy)
    }
}

/// 与 scripts/dockgroup.py 的 `__version__` 保持一致。
let VERSION = "1.4.0"
