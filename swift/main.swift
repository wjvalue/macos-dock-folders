// swift/main.swift
//
// dockgroup 的 Swift 实现。
//
// 目标：把 Python 那半边完全替换掉，做到**零运行期依赖**
// （CLT 只在编译期需要；配合预编译二进制，用户端连 CLT 都不必装）。
//
// 迁移策略 = 绞杀者模式：Swift 版与 Python 版**并存**，每个子命令都用
// 「输出对照测试」验证一致（见 tools/compare_cli.sh），全部对齐后再切换。
// 这套方法论在 tools/mosaic_poc 那个图像 spike 里已经验证过 ——
// 靠肉眼判断「看着一样」会漏掉 10% 量级的差异。

import Foundation

func showVersion() {
    print("dockgroup \(VERSION) (swift)")
}

func showHelp() {
    print("""
    dockgroup \(VERSION) —— macOS Dock 分组管理

    用法：dg <命令> [参数]

    已搬到 Swift 版：
      doctor              体检：依赖、落盘、签名、隔离、产物路径
      list                列出配置里的分组
      init                扫描当前 Dock 生成起始配置
      rebuild             只重建图标与 App，不动 Dock
      apply               生成 App 并写入 Dock
      style [组名] <材质>  换面板底色（毛玻璃材质）
      layout [组名] <模式> 换面板排列

    还没搬（敲了会提示你去用 Python 版）：
      add  del  open  restore  new  preview  remove  clean
      watch-install  watch-uninstall  test  logs  gui

    迁移进行中：两套实现并存，逐个命令对齐后再切换。
    """)
}

let rawArgs = Array(CommandLine.arguments.dropFirst())

guard let cmd = rawArgs.first else {
    showHelp()
    exit(0)
}
let args = Array(rawArgs.dropFirst())

/// 还没搬过来的子命令，给出明确指引而不是含糊的「未知命令」。
let notYetPorted: Set<String> = [
    "apply", "style", "layout",
    "add", "del", "open", "remove", "clean", "restore",
    "new", "preview", "watch-install", "watch-uninstall",
    "test", "logs", "gui",
]

switch cmd {
case "--version", "-v", "version":
    showVersion()

case "--help", "-h", "help":
    showHelp()

case "list":
    cmdList(args)

case "doctor":
    cmdDoctor(args)

case "init":
    cmdInit(args)

case "rebuild":
    cmdRebuild(loadConfig(), args)

case "apply":
    cmdApply(loadConfig(), args)

case "style":
    cmdStyle(loadConfig(), args)

case "layout":
    cmdLayout(loadConfig(), args)

case "__dock-sync":
    // 内部调试命令：只跑 dock_sync，把结果写进 `DOCKGROUP_DOCK_PLIST` 指定的文件。
    // 对照测试拿它和 Python 的 dock_sync 比**写出的 Dock 配置字节** ——
    // 这是整个工具唯一会改用户 Dock 的地方，也是最该盯死的一段。
    // 没设那个环境变量时拒绝运行：绝不能拿这个命令去动真 Dock。
    guard let override = dockPlistOverride else {
        FileHandle.standardError.write(
            "拒绝运行：__dock-sync 必须配合 DOCKGROUP_DOCK_PLIST 使用\n".data(using: .utf8)!)
        exit(2)
    }
    let syncCfg = loadConfig()
    let prune = !args.contains("--keep-originals")
    do {
        try dockSync(syncCfg, only: nil, prune: prune)
        print("\(override.path)  ok")
    } catch let e as DgError {
        FileHandle.standardError.write("\(e.message)\n".data(using: .utf8)!)
        exit(1)
    }

case "__build-group":
    // 内部调试命令：只构建一个分组，**不重启 Dock**。
    // 对照测试必须用它 —— refresh_groups 会 killall Dock，从沙箱里跑会把当前
    // 命令连带打死（exit 137、零输出，看着像没执行），根本拿不到结果。
    guard let groupName = args.first else {
        FileHandle.standardError.write("用法：__build-group <组名>\n".data(using: .utf8)!)
        exit(2)
    }
    let dbgCfg = loadConfig()
    guard let dbgGroup = dbgCfg.group(named: groupName) else {
        FileHandle.standardError.write("找不到分组「\(groupName)」\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        if dbgGroup.placement == "right" {
            try buildGroup(dbgGroup, style: dbgCfg.style, seed: false)
        } else {
            try buildLauncherApp(dbgGroup, style: dbgCfg.style,
                                 material: groupMaterial(dbgCfg, dbgGroup),
                                 layout: groupLayout(dbgCfg, dbgGroup), seed: false)
        }
        print("\(groupName)  ok")
    } catch let e as DgError {
        FileHandle.standardError.write("\(e.message)\n".data(using: .utf8)!)
        exit(1)
    }

case "__dump-config":
    // 内部调试命令：把读到的配置重新序列化打出来。
    // 用途是验证「读进来再写出去」和 Python 的 json.dumps 逐字节一致 ——
    // 配置模块没有别的正确性关卡，而这个格式一旦漂了，
    // groups.json 的 diff 就会全是噪音（2026-09-20 踩过一次）。
    print(JSONValue.object(loadConfig()).serialized(), terminator: "")

case "__make-mosaic":
    // 内部调试命令：直接合成一张分组图标。对照测试拿它和 Python 的 make_mosaic
    // 比像素 —— 走固定输入图标，把 app_icons 那层变量隔离掉。
    guard args.count >= 4 else {
        FileHandle.standardError.write(
            "用法：__make-mosaic <style> <size> <out.png> <icon.png>...\n".data(using: .utf8)!)
        exit(2)
    }
    makeMosaic(Array(args.dropFirst(3)), out: args[2],
               size: Int(args[1]) ?? 1024, style: args[0])

case "__grab-icons":
    // 内部调试命令：把若干 App 的图标抓到指定目录，用来对照 Python 的 app_icons。
    // 只打印「名字 + 成功/失败」，不带路径 —— 两边缓存目录不同，带路径就没法 diff 了。
    guard args.count >= 2 else {
        FileHandle.standardError.write(
            "用法：__grab-icons <输出目录> <App 路径>...\n".data(using: .utf8)!)
        exit(2)
    }
    let dir = URL(fileURLWithPath: args[0])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let apps = args.dropFirst().map { URL(fileURLWithPath: $0) }
    let got = appIcons(apps)
    for a in apps {
        let name = a.deletingPathExtension().lastPathComponent
        if let p = got[a.path] {
            let dst = dir.appendingPathComponent("\(name).png")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: p, to: dst)
            print("\(name)  ok")
        } else {
            print("\(name)  失败")
        }
    }

default:
    if notYetPorted.contains(cmd) {
        let py = SCRIPT_DIR.appendingPathComponent("dockgroup.py").path
        FileHandle.standardError.write("""
        「\(cmd)」还没搬到 Swift 版。
        暂时用 Python 版：/usr/bin/python3 "\(py)" \(cmd) \(args.joined(separator: " "))

        """.data(using: .utf8)!)
        exit(3)
    }
    FileHandle.standardError.write("未知命令：\(cmd)（用 --help 看用法）\n".data(using: .utf8)!)
    exit(2)
}
