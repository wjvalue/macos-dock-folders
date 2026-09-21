// swift/Core/Paths.swift
//
// 路径常量。照抄 scripts/dockgroup.py 顶部那组定义，不凭记忆改 ——
// 迁移期两套实现必须指向**同一个** ~/Dock Groups，否则对照测试失去意义。

import Foundation

let HOME = FileManager.default.homeDirectoryForCurrentUser

/// 仓库根目录由编译脚本烧进来（见 swift/build.sh 生成的 BuildInfo.swift）。
/// Swift 二进制没有 Python 的 `__file__`，位置只能在编译期定死 ——
/// 这和 Python 版那个 `dg` 短命令写死路径是同一个思路。
let REPO_ROOT = URL(fileURLWithPath: BUILD_REPO_ROOT).standardizedFileURL
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

// iOS 主屏文件夹的几何比例（相对文件夹边长）
let ICON_INSET = 0.075
let BG_RADIUS = 0.235

/// 与 scripts/dockgroup.py 的 `__version__` 保持一致。
let VERSION = "1.1.0"
