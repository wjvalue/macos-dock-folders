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

    命令：
      doctor              体检：依赖、落盘、签名、隔离、产物路径
      list                列出配置里的分组
      init                扫描当前 Dock 生成起始配置
      apply               生成 App 并写入 Dock
      rebuild             只重建图标与 App，不动 Dock
      style [组名] <风格>  切换拼贴图标风格
      layout [组名] <模式> 切换面板排列
      add <组名> <App>    把 App 加进分组
      del <组名> <App>    只删别名，不碰真实 App
      open <组名>         打开分组文件夹
      restore             从备份恢复 Dock

    当前是迁移中的 Swift 实现，命令逐个搬过来，没搬的会明确报错。
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
    "doctor", "init", "apply", "rebuild", "style", "layout",
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

case "__dump-config":
    // 内部调试命令：把读到的配置重新序列化打出来。
    // 用途是验证「读进来再写出去」和 Python 的 json.dumps 逐字节一致 ——
    // 配置模块没有别的正确性关卡，而这个格式一旦漂了，
    // groups.json 的 diff 就会全是噪音（2026-09-20 踩过一次）。
    print(JSONValue.object(loadConfig()).serialized(), terminator: "")

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
