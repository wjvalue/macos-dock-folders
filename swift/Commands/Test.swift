// swift/Commands/Test.swift
//
// `dg test` —— 启动一个分组的启动器 App 做真机测试。
// 对应 Python 的 cmd_test。

import Foundation

func cmdTest(_ cfg: JSONObject, _ args: [String]) {
    if args.isEmpty {
        fatal("请指定分组名")
    }
    guard let g = cfg.group(named: args[0]) else {
        fatal("没有分组「\(args[0])」")
    }
    if g.placement == "right" {
        fatal("该分组用文件夹 Stack 模式，直接在 Dock 里点就行")
    }
    let app = APPS.appendingPathComponent("\(g.name).app")
    guard FileManager.default.fileExists(atPath: app.path) else {
        fatal("启动器还没构建：\(app.path)，先跑一次 apply")
    }
    // 对照测试模式下不真启动（Python 版同款开关）—— 否则每轮测试拉起两个进程
    if dockPlistOverride == nil {
        run("/usr/bin/open", [app.path])
    }
    print("已启动 \(app.path)")
    print("运行日志：\(CACHE.appendingPathComponent(g.name + ".launch.log").path)")
}
