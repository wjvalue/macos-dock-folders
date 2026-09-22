// swift/Commands/Watch.swift
//
// `dg watch-install` / `dg watch-uninstall` —— LaunchAgents 文件夹监听。
// 对应 Python 的 cmd_watch_install / cmd_watch_uninstall。
//
// DOCKGROUP_DOCK_PLIST（对照测试开关）下的行为：plist 写进隔离目录的
// watch-test.plist（绝不碰真实的 ~/Library/LaunchAgents），launchctl 一概
// 不碰 —— 输出走「没有 launchd 权限」分支（沙箱里本来也只有这条能走）。
//
// plist 的键顺序必须是**字母序**：plistlib.dumps 默认 sort_keys=True，
// PlistValue 的渲染器不替你排序。嵌套字典（EnvironmentVariables）同理。

import Foundation

let WATCH_LABEL = "local.dockgroup.watch"

private func agentPlistURL() -> URL {
    if let o = dockPlistOverride {
        return o.deletingLastPathComponent().appendingPathComponent("watch-test.plist")
    }
    return HOME.appendingPathComponent("Library/LaunchAgents")
        .appendingPathComponent("\(WATCH_LABEL).plist")
}

private func watchPayload(_ cfg: JSONObject) -> PlistValue {
    // 引擎入口复用 engineCommand()：dg 二进制能直接 exec；万一退回仓库里的
    // dockgroup.py（.py 不能直接 exec 出可靠解释器），保留 /usr/bin/python3 前缀。
    //
    // ⚠️ 不能写死 python3 + 仓库脚本：预编译安装（install.command 路径 A）根本
    // 不装 Pillow，dockgroup.py 顶部 `from PIL import` 缺包直接 sys.exit ——
    // watch agent 每次被文件夹变动触发都静默崩，自动刷新从未生效。
    // （2026-09-22 对比外部 PR 时发现；Python 侧 cmd_watch_install 有同款修复。）
    let ec = engineCommand()
    let progArgs: [PlistValue] = ec.hasSuffix(".py")
        ? [.string("/usr/bin/python3"), .string(ec), .string("rebuild"), .string("--quiet")]
        : [.string(ec), .string("rebuild"), .string("--quiet")]
    return .dict([
        // DOCKGROUP_HOME 必须显式带进 agent：launchd 环境里没有用户的 shell
        // 配置，BASE 若是自定义位置，agent 里的 rebuild 会找错配置目录。
        ("EnvironmentVariables", .dict([
            ("DOCKGROUP_HOME", .string(BASE.path)),
        ])),
        ("Label", .string(WATCH_LABEL)),
        ("ProgramArguments", .array(progArgs)),
        ("RunAtLoad", .bool(false)),
        ("ThrottleInterval", .integer(5)),
        ("WatchPaths", .array(cfg.groups.map { .string(BASE.appendingPathComponent($0.name).path) })),
    ])
}

func cmdWatchInstall(_ cfg: JSONObject, _ args: [String]) {
    let agent = agentPlistURL()
    try? FileManager.default.createDirectory(at: agent.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do {
        try watchPayload(cfg).xmlData().write(to: agent)
    } catch {
        FileHandle.standardError.write("写入失败：\(agent.path)\n".data(using: .utf8)!)
        exit(1)
    }
    let domain = "gui/\(getuid())"
    // Python: bootout 静默，bootstrap 带输出；测试模式直接走「没权限」分支
    if dockPlistOverride != nil {
        print("已写入 \(agent.path)")
        print("但当前进程没有 launchd 权限，无法自动加载。请在你自己的「终端」里执行一次：")
        print("  launchctl bootstrap \(domain) \(agent.path)")
    } else {
        _ = run("/bin/sh", ["-c", "launchctl bootout \(domain) \(agent.path) >/dev/null 2>&1"])
        let r = run("/bin/sh", ["-c", "launchctl bootstrap \(domain) \(agent.path)"])
        if r.status == 0 {
            print("已写入并启用 \(agent.path)")
            print("自动监听生效：往分组文件夹里加/删 App，图标会自动更新。")
        } else {
            print("已写入 \(agent.path)")
            print("但当前进程没有 launchd 权限，无法自动加载。请在你自己的「终端」里执行一次：")
            print("  launchctl bootstrap \(domain) \(agent.path)")
        }
    }
    print("注：之后新增分组文件夹，需要重新跑一次 watch-install 才会被监听。")
}

func cmdWatchUninstall(_ cfg: JSONObject, _ args: [String]) {
    let agent = agentPlistURL()
    if dockPlistOverride == nil {
        _ = run("/bin/sh", ["-c", "launchctl bootout gui/\(getuid()) \(agent.path)"])
    }
    try? FileManager.default.removeItem(at: agent)   // Python unlink(missing_ok=True)
    print("自动监听已卸载")
}
