// swift/Commands/Doctor.swift
//
// `dg doctor` —— 体检。对应 Python 的 cmd_doctor()，输出要逐字符一致。
//
// 迁移期照抄的取舍：Swift 版仍然报 python3 / Pillow 这两项依赖 —— 因为
// 现在引擎还在 Python 手上，缺了确实跑不起来，而且对照测试要求两边输出一致。
// 等 Python 那半边删掉，这两项会跟着消失。

import Foundation

/// 对应 Python 的 `len(re.findall(r"^\s+\d+\)", ident, re.M))`。
private func countIdentityLines(_ text: String) -> Int {
    guard let re = try? NSRegularExpression(pattern: "^\\s+\\d+\\)",
                                            options: [.anchorsMatchLines]) else { return 0 }
    return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
}

func cmdDoctor(_ args: [String]) {
    print("dockgroup \(VERSION)")
    print()

    // sys.executable 在两边必须是同一个值，所以这里探测而不是写死 ——
    // /usr/bin/python3 是个 shim，它报出来的真实路径在每台机器上未必一样。
    let py = "/usr/bin/python3"
    let pyExe = run(py, ["-c", "import sys; print(sys.executable)"]).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pyVer = run(py, ["-c", "import sys; print(sys.version.split()[0])"]).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pyReal = pyExe.isEmpty ? py : pyExe

    let checks: [(String, String, Bool)] = [
        ("python3", "运行脚本本身", run(pyReal, ["-c", "print(1)"]).status == 0),
        ("Pillow", "合成拼贴图标 (PIL)", run(pyReal, ["-c", "import PIL"]).status == 0),
        ("osascript", "JXA 调 AppKit / Foundation", which("osascript") != nil),
        ("swiftc", "编译启动器 App（左侧模式）", which("swiftc") != nil),
        ("codesign", "App 临时签名", which("codesign") != nil),
        ("iconutil", "打包 .icns", which("iconutil") != nil),
        ("sips", "PNG 缩放", which("sips") != nil),
    ]

    var allok = true
    for (tool, why, good) in checks {
        allok = allok && good
        print("  \(good ? "✅" : "❌")  \(pad(tool, 10)) \(why)")
    }

    print()
    print("  Python   : \(pyReal)  (\(pyVer))")
    print("  落盘目录 : \(BASE.path)")
    let cfgText = FileManager.default.fileExists(atPath: CONFIG_PATH.path)
        ? CONFIG_PATH.path : "（还没建，跑 init）"
    print("  配置文件 : \(cfgText)")
    print("  依赖结论 : \(allok ? "齐全，可以用了" : "有缺失，见下")")

    if !allok {
        // Pillow 和 CLT 是两条独立的路，缺哪个给哪个的命令。
        // 以前不分情况一律提示 xcode-select —— 只缺 Pillow 的人照着装完 CLT
        // 回来还是报错，白折腾一轮。
        let missing = Set(checks.filter { !$0.2 }.map(\.0))

        if missing.contains("Pillow") {
            print()
            print("  Pillow 不在 macOS 自带依赖里，需要单独装：")
            print("    /usr/bin/python3 -m pip install --user Pillow")
            print("  必须装给 /usr/bin/python3（本工具固定用它，别的解释器读不到）。")
        }

        if !missing.isDisjoint(with: ["swiftc", "codesign", "iconutil", "sips"]) {
            // 只有 swiftc 来自 CLT，别把 codesign / iconutil / sips 也算进去 ——
            // 那是 macOS 自带的（xcrun -f 解析回 /usr/bin，CLT 的 bin 里没有它们）。
            if missing.contains("swiftc") {
                print()
                print("  swiftc 随 Xcode Command Line Tools 提供：")
                print("    xcode-select --install")
                print("  只想用右侧文件夹模式的话，缺 swiftc 也能跑（placement 设成 right）。")
            }
            let sysmiss = missing.intersection(["codesign", "iconutil", "sips"]).sorted()
            if !sysmiss.isEmpty {
                print()
                print("  这几个是 macOS 自带的，正常不该缺：" + sysmiss.joined(separator: "、"))
                print("  缺了说明系统环境异常（检查 /usr/bin 是否被改动过），装 CLT 解决不了。")
            }
        }
    }

    // ── 分发与签名 ──
    // 这一节存在的理由：签名身份和隔离属性都属于「本机自测一路绿灯、发出去才炸」
    // 的事。用户来报「打不开」，先看这里就能分清是哪一种。
    print()
    print("  分发与签名：")

    let ident = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).text
    let nId = countIdentityLines(ident)
    if nId > 0 {
        print("    ✅ 签名身份 : \(nId) 个可用（能签 Developer ID，发给别人不会被拦）")
    } else {
        print("    ⚠️ 签名身份 : 无 —— 只能用 ad-hoc 签名（codesign -s -）")
        print("              本机自用没问题。把 .app 发给别人，对方会被 Gatekeeper")
        print("              拦下，需要右键→打开，或清掉隔离属性。见 README「分发与签名」。")
    }

    let built = ((try? FileManager.default.contentsOfDirectory(
        at: APPS, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "app" }
        .sorted { pyLess($0.path, $1.path) }

    if built.isEmpty {
        print("    ·  产物     : 还没生成过 App")
        return
    }

    let dirty = built.filter { hasQuarantine($0) }.map { $0.deletingPathExtension().lastPathComponent }
    if !dirty.isEmpty {
        print("    ⚠️ 隔离属性 : \(dirty.joined(separator: "、")) 带 com.apple.quarantine")
        print("              首次打开会被拦。跑 dg rebuild / dg gui 会自动清掉。")
    } else {
        print("    ✅ 隔离属性 : \(built.count) 个 App 都干净")
    }

    // 产物里的路径是否还有效。
    // .app 的 Info.plist 里存着两项**绝对路径**：DockGroupScript（引擎脚本）
    // 和 DockGroupFolder（分组文件夹）。仓库被移动/改名之后这些路径就失效，
    // 而失效的表现是「拖 App 到 Dock 图标上没反应」—— 启动器只把原因写进
    // .cache/<组>.launch.log，界面上毫无提示（issue #1 里用户建议改用相对路径，
    // 说的就是这个痛点）。这里主动查出来，省得靠猜。
    var stale: [String] = []
    for a in built {
        let name = a.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: a.appendingPathComponent("Contents/Info.plist")),
              let pl = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any] else {
            stale.append("\(name)：读不到 Info.plist")
            continue
        }
        let miss = ["DockGroupScript", "DockGroupFolder"].filter { key in
            guard let p = pl[key] as? String, !p.isEmpty else { return false }
            return !FileManager.default.fileExists(atPath: p)
        }
        if !miss.isEmpty {
            stale.append("\(name)：\(miss.joined(separator: "、")) 指向的路径已不存在")
        }
    }
    if stale.isEmpty {
        print("    ✅ 产物路径 : \(built.count) 个 App 的依赖路径都在")
    } else {
        print("    ⚠️ 产物路径 : \(stale.count) 个 App 的依赖路径失效")
        for s in stale { print("                  \(s)") }
        print("              表现是「拖 App 到 Dock 图标上没反应」。跑 dg rebuild 重建即可。")
    }
}
