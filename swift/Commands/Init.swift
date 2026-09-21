// swift/Commands/Init.swift
//
// `dg init` —— 扫描当前 Dock，生成起始配置。
// 对应 Python 的 cmd_init()，输出与写出的 groups.json 都要逐字符一致。
//
// ⚠️ 这是第一个**有副作用**的命令（会写 groups.json）。
// 对照测试不能像 list / doctor 那样直接跑两遍 —— 第二遍会因为「配置已存在」
// 而走进不同的分支。tools/compare_cli.sh 里用 DOCKGROUP_HOME 隔离 + 每轮清空
// 来处理，同时也顺带覆盖了「已存在」那条分支。

import Foundation

func cmdInit(_ args: [String]) {
    let force = args.contains("--force")

    // Python 用 sys.exit(msg)：消息进 stderr、退出码 1
    if FileManager.default.fileExists(atPath: CONFIG_PATH.path) && !force {
        FileHandle.standardError.write(
            "\(CONFIG_PATH.path) 已存在（要覆盖请加 --force）\n".data(using: .utf8)!)
        exit(1)
    }

    let apps = dockAppList()
    if apps.isEmpty {
        FileHandle.standardError.write(
            "读不到 Dock 里的 App，先确认 Dock 正常运行\n".data(using: .utf8)!)
        exit(1)
    }

    let name = "分组1"
    var cfg = JSONObject()
    cfg["style"] = .string(DEFAULT_STYLE)
    cfg["groups"] = .array([
        .object(JSONObject([
            ("name", .string(name)),
            ("enabled", .bool(false)),      // 示例分组，别自动应用
            ("placement", .string("left")),
            ("apps", .array(apps.prefix(4).map { .string($0) })),
        ])),
    ])
    try? saveConfig(cfg)

    print("已生成 \(CONFIG_PATH.path)")
    print()
    print("你 Dock 里现有的 App（挑几个凑一组，改到配置的 apps 列表里）：")
    for (i, a) in apps.enumerated() {
        let stem = URL(fileURLWithPath: a).deletingPathExtension().lastPathComponent
        // 对应 Python 的 {i:2}：数字右对齐宽度 2
        print("  \(String(format: "%2d", i + 1)). \(stem)")
    }
    print()
    print("配置里先放了一个示例分组「\(name)」，enabled=false 不会被自动应用。")
    print("提示：也可以直接用 new 命令建组，不用手改 JSON：")
    print("  \(SCRIPT_DIR.appendingPathComponent("dockgroup.py").path) new \(name) \"WorkBuddy\" \"Google Chrome\"")
}
