// swift/Commands/Gui.swift
//
// `dg gui` —— 打开图形界面（分组管理窗口）。
// 对应 Python 的 cmd_gui。第一次跑要编译打包（十来秒），之后走缓存秒开。

import Foundation

func cmdGui(_ cfg: JSONObject, _ args: [String]) {
    let app = buildManagerApp(force: args.contains("--rebuild"))
    print("管理窗口：\(app.path)")
    // 对照测试模式下不真开（Python 版同款开关，与 open / test 一致）
    if dockPlistOverride == nil {
        run("/usr/bin/open", [app.path])
    }
    print("已打开。加 App、换外观、应用/回滚都能在里面点。")
    print("（改不了界面本身的话，源码在 \(SCRIPT_DIR.appendingPathComponent(MANAGER_SRC).path)）")
}
