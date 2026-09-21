// swift/Core/Quarantine.swift
//
// 隔离属性（com.apple.quarantine）与启动器进程管理。
// 对应 Python 的 quarantine_listing / has_quarantine / strip_quarantine / kill_launchers。
//
// ⚠️ 判定方式必须和 Python 版**完全一致**（同样跑 `xattr -r -l` 看输出里有没有
// 那个字符串），否则对照测试会假失败。别图省事改用 URLResourceKey 的
// quarantineProperties —— 语义相近但不是一回事。

import Foundation

/// 递归列出整棵目录树上的扩展属性，用来判断有没有隔离标记。
func quarantineListing(_ path: URL) -> String {
    run("/usr/bin/xattr", ["-r", "-l", path.path]).text
}

func hasQuarantine(_ path: URL) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) else { return false }
    return quarantineListing(path).contains("com.apple.quarantine")
}

/// 清掉整棵目录树上的隔离属性，返回是否真的清过。
///
/// 为什么构建完必须做：产物要能脱离「我这台机器」运行。三条路都会带进来 ——
///   ① 下载 release zip 解压：源码带隔离，生成的 .app 会继承；
///   ② 用 Safari / 邮件收到别人打包的 .app：直接带；
///   ③ 从 U 盘、网络卷、共享目录拷过来的仓库。
///
/// 本机开发永远复现不了（本地创建的文件没有这个标记），只有发出去才炸。
@discardableResult
func stripQuarantine(_ path: URL) -> Bool {
    guard hasQuarantine(path) else { return false }
    run("/usr/bin/xattr", ["-cr", path.path])
    return true
}

/// 结束正在运行的启动器实例，返回是否真杀到了。
///
/// **为什么每次重建之后都必须做这一步**：启动器收起后还要常驻 kIdleSeconds 秒
/// （立刻退会让 Dock 报「应用程序"X"已不能再打开」），而它的布局 / 材质 / 成员
/// 都是**进程启动时**从 Info.plist 读进内存的 —— 之后你把 bundle 重建十遍也影响
/// 不到那个已经在跑的进程，点 Dock 图标走 reopen 还是回到它，于是面板维持旧样子。
///
/// 2026-09-20 实测踩过：全局 layout 从 dock 改成 auto，groups.json 和
/// Info.plist 里都已经是 auto，apply 也重建了 bundle，但点开面板仍是旧的
/// dock 条 —— 因为那个旧进程还活着。
///
/// 那 0.4 秒是等 LaunchServices 消化进程退出，否则紧接着点击可能撞上
/// 「已不能再打开」。
///
/// 设了 `DOCKGROUP_DOCK_PLIST`（对照测试模式）时直接返回 false、不动任何进程 ——
/// 否则跑一次对照测试会把用户正开着的面板全关掉。
@discardableResult
func killLaunchers() -> Bool {
    if dockPlistOverride != nil { return false }
    let r = run("/usr/bin/pkill", ["-f", "DockGroupLauncher"])
    if r.status == 0 {
        Thread.sleep(forTimeInterval: 0.4)
        return true
    }
    return false
}
