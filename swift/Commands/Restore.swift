// swift/Commands/Restore.swift
//
// `dg restore` —— 出错了回滚 Dock。
// 对应 Python 的 cmd_restore。
//
// 测试开关与 dock_write 同款：设了 DOCKGROUP_DOCK_PLIST 时把备份字节写到替身
// 文件、不跑 defaults import / killall Dock —— 否则对照测试会把用户真 Dock
// 覆盖掉（这是唯一一条「故意绕过 dock_write 直灌字节」的路径，原始字节
// 进哪里都必须可测）。

import Foundation

func cmdRestore(_ cfg: JSONObject, _ args: [String]) {
    let src: URL
    // 展示用的原始字符串：Python 里 f"{Path(arg)}" 基本保留原样（绝对路径场景
    // 完全一致；"./x" 归一化那条边角不进测试，不做）。
    var shown: String
    if let a = args.first {
        src = URL(fileURLWithPath: a)
        shown = a
    } else {
        // Python: sorted(BACKUP.glob("com.apple.dock-*.plist")) 取最后一个；
        // BACKUP 不存在时 glob 返回空 —— 这里同样按「没有可用备份」处理。
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: BACKUP, includingPropertiesForKeys: nil)) ?? []
        let cands = items
            .filter { $0.lastPathComponent.hasPrefix("com.apple.dock-")
                   && $0.lastPathComponent.hasSuffix(".plist") }
            .sorted { pyLess($0.path, $1.path) }
        guard let latest = cands.last else {
            fatal("没有可用备份")
        }
        // ⚠️ contentsOfDirectory 返回的 URL 是**解析过符号链接**的
        // （/tmp → /private/tmp），而 Python 的 Path.glob 保留输入前缀 ——
        // 打印路径必须从 BACKUP 前缀拼回去，否则对照测试差一个 /private。
        src = BACKUP.appendingPathComponent(latest.lastPathComponent)
        shown = src.path
    }

    let data: Data
    do {
        data = try Data(contentsOf: src)
    } catch {
        // Python 这条是 FileNotFoundError traceback（崩溃路径）；给个明确的
        // 报错比复刻 traceback 有用，该分支不进对照测试。
        fatal("读不到备份文件：\(src.path)")
    }
    // plistlib.loads(data) —— 只做合法性校验
    guard (try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil)) != nil else {
        // Python 这条是 plistlib 异常 traceback（崩溃路径），同上不进对照测试
        fatal("备份文件不是合法 plist：\(src.path)")
    }

    if let override = dockPlistOverride {
        try? data.write(to: override)       // 对照测试：替身文件收下原始字节
    } else {
        // Python check=True：失败抛 CalledProcessError（崩溃路径）
        let r = run("/usr/bin/defaults", ["import", DOCK_DOMAIN, "-"], input: data)
        guard r.status == 0 else {
            fatal("defaults import 失败（退出码 \(r.status)）")
        }
        run("/usr/bin/killall", ["Dock"])
    }
    print("已从 \(shown) 恢复 Dock")
}
