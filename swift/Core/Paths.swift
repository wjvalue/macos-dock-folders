// swift/Core/Paths.swift
//
// 路径常量。照抄 scripts/dockgroup.py 顶部那组定义，不凭记忆改 ——
// 迁移期两套实现必须指向**同一个** ~/Dock Groups，否则对照测试失去意义。

import Foundation

let HOME = FileManager.default.homeDirectoryForCurrentUser

/// 仓库根目录。解析顺序：
///   1. 环境变量 `DOCKGROUP_REPO`（测试 / 手动覆盖）
///   2. 标记文件 `~/.local/bin/.dg-repo-root`（install.command 安装预编译
///      二进制时写入 —— 分发出去的二进制里烧着的编译期路径是构建机的，
///      对用户没意义）
///   3. 编译期烧入的 `BUILD_REPO_ROOT`（本地开发，见 swift/build.sh 生成的
///      BuildInfo.swift）。Swift 二进制没有 Python 的 `__file__`，本地开发
///      场景只能在编译期定死。
let REPO_ROOT: URL = {
    let env = ProcessInfo.processInfo.environment
    if let r = env["DOCKGROUP_REPO"], !r.isEmpty {
        return URL(fileURLWithPath: r).standardizedFileURL
    }
    let marker = HOME.appendingPathComponent(".local/bin/.dg-repo-root")
    if let s = try? String(contentsOf: marker, encoding: .utf8) {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p).standardizedFileURL
        }
    }
    return URL(fileURLWithPath: BUILD_REPO_ROOT).standardizedFileURL
}()
let SCRIPT_DIR = REPO_ROOT.appendingPathComponent("scripts")

/// 落盘目录。可用 `DOCKGROUP_HOME` 覆盖 —— 对照测试要靠它把两边隔离到同一处，
/// Python 版也是同款行为。
let BASE: URL = {
    if let h = ProcessInfo.processInfo.environment["DOCKGROUP_HOME"], !h.isEmpty {
        return URL(fileURLWithPath: h).standardizedFileURL
    }
    return HOME.appendingPathComponent("Dock Groups")
}()

let CACHE = BASE.appendingPathComponent(".cache")
let BACKUP = BASE.appendingPathComponent(".backup")
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

/// 与 scripts/dockgroup.py 的 `__version__` 保持一致。
let VERSION = "1.3.1"
