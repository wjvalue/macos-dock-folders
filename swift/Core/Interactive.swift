// swift/Core/Interactive.swift
//
// 交互模式的地基：读输入、确认、序号解析、列已装 App、选分组 / 选 App。
// 对应 Python 的 ask / confirm / parse_selection / list_installed_apps /
// _require_tty / group_app_count / pick_group / pick_apps。
//
// 为什么需要：日常 add/new 最烦的不是命令本身，而是「得记组名、得拼对 App 名」。
// 不带参数跑 add / new 就进入引导。纯 readLine() 实现，不引入任何新依赖。
//
// ⚠️ 对照测试覆盖不了交互路径（要真实终端）—— 真正能测的只有 _require_tty
// 那条「没终端就报错」的分支。这一层的移植正确性靠逐行对照 Python 源码保证。

import Foundation

/// 分页大小（Python 的 PAGE_SIZE）。
let PAGE_SIZE = 15

/// 交互模式必须有真实终端；管道/脚本调用时给出用法提示，避免 readLine() 死循环。
func requireTty(_ cmd: String) {
    if isatty(STDIN_FILENO) == 0 {
        fatal("交互模式需要终端。在脚本里请用带参数的形式：dg \(cmd) <组名> \"App\" ...")
    }
}

/// 读一行输入。EOF 当默认值。
/// ⚠️ 已知差异：Python 捕获 KeyboardInterrupt 打「已取消」后正常返回；
/// Swift 默认 SIGINT 直接终止进程。交互路径进不了对照测试，中断的结局
/// （退出）两边一致，先接受这条差异，注释在此立此存照。
func ask(_ prompt: String, _ deflt: String = "") -> String {
    let suffix = deflt.isEmpty ? "" : " [\(deflt)]"
    print("\(prompt)\(suffix)> ", terminator: "")
    guard let line = readLine() else {
        print()
        return deflt
    }
    return line.trimmingCharacters(in: .whitespaces)
}

/// yes/no。default=true 时空回车也算确认。
func confirm(_ prompt: String, default deflt: Bool = true) -> Bool {
    let s = ask(prompt, deflt ? "y" : "n").lowercased()
    return s == "y" || s == "yes" || (deflt && s.isEmpty)
}

/// '1' / '1,3' / '2-4' → 0 基下标集合。非法返回 nil。
func parseSelection(_ s: String, _ count: Int) -> Set<Int>? {
    let re = try? NSRegularExpression(pattern: "^(\\d+)(?:-(\\d+))?$")
    guard let re else { return nil }
    var picks = Set<Int>()
    let cleaned = s.replacingOccurrences(of: " ", with: "")
    for part in cleaned.split(separator: ",", omittingEmptySubsequences: true) {
        let range = NSRange(part.startIndex..., in: part)
        guard let m = re.firstMatch(in: String(part), range: range) else { return nil }
        // Python 的 int() 没有上限；超宽的数字在 Swift 里 Int() 失败，
        // 走「非法输入」分支 —— 与 Python 的 b > count 分支殊途同归。
        guard let a = regexGroupInt(m, 1, part) else { return nil }
        var b = a
        if m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound,
           let v = regexGroupInt(m, 2, part) {
            b = v
        }
        if a < 1 || b > count || a > b { return nil }
        for i in (a - 1)..<b { picks.insert(i) }
    }
    return picks.isEmpty ? nil : picks
}

/// 取正则捕获组并转 Int；组不存在或转不了（超宽数字）返回 nil。
/// 单独拆成函数 —— 内联写在 guard 里会让编译器类型检查超时。
private func regexGroupInt(_ m: NSTextCheckingResult, _ idx: Int, _ s: Substring) -> Int? {
    guard let r = Range(m.range(at: idx), in: s) else { return nil }
    return Int(s[r])
}

/// 扫描所有应用目录 → [(显示名, 路径)]，按显示名去重、按名排序。
func listInstalledApps() -> [(name: String, url: URL)] {
    let fm = FileManager.default
    var seen = Set<String>()
    var out: [(name: String, url: URL)] = []
    var dirs = APP_DIRS
    dirs.append(HOME.appendingPathComponent("Applications").path)
    for d in dirs {
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: d), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
        // Python: sorted(iterdir(), key=stem.lower())，稳定排序。先按路径排一遍
        // 再按 lowercased stem 稳定排，把 iterdir 的任意顺序钉死。
        let sorted = items.sorted { pyLess($0.path, $1.path) }
            .sorted { $0.deletingPathExtension().lastPathComponent.lowercased()
                      < $1.deletingPathExtension().lastPathComponent.lowercased() }
        for e in sorted {
            var isDir: ObjCBool = false
            let stem = e.deletingPathExtension().lastPathComponent
            guard e.pathExtension == "app",
                  fm.fileExists(atPath: e.path, isDirectory: &isDir), isDir.boolValue,
                  !seen.contains(stem) else { continue }
            seen.insert(stem)
            out.append((stem, e))
        }
    }
    return out
}

/// 分组里有几个 App：文件夹优先，没建文件夹时回退读配置。
func groupAppCount(_ g: JSONObject) -> Int {
    let apps = readFolderApps(BASE.appendingPathComponent(g.name))
    if !apps.isEmpty { return apps.count }
    return g.apps.count
}

/// 交互式选一个分组；只有一个时自动选中。取消返回 nil。
func pickGroup(_ cfg: JSONObject, _ prompt: String = "选择分组") -> JSONObject? {
    let groups = cfg.groups
    if groups.isEmpty {
        print("还没有任何分组，先建一个：dg new")
        return nil
    }
    if groups.count == 1 {
        print("\n只有一个分组「\(groups[0].name)」，直接用它。")
        return groups[0]
    }
    print("\n\(prompt)：")
    for (i, g) in groups.enumerated() {
        print("  \(String(format: "%3d", i + 1)). \(pad(g.name, 12)) \(groupAppCount(g)) 个 App")
    }
    while true {
        let s = ask("输入序号（q=取消）").lowercased()
        if s == "q" || s == "quit" || s == "exit" { return nil }
        guard let picks = parseSelection(s, groups.count) else {
            print("  输入无效：敲序号，如 1")
            continue
        }
        return groups[picks.sorted()[0]]
    }
}

/// 交互式多选 App → [URL]。
///
/// group_name 给定时，该组里已有的 App 会被标记并禁止重复选择。
/// 流程：输关键词过滤 → 翻页/敲序号多选 → q 完成。
func pickApps(_ cfg: JSONObject, _ groupName: String?) -> [URL] {
    let installed = listInstalledApps()
    if installed.isEmpty {
        print("  扫描不到已安装的 App")
        return []
    }
    let exclude: Set<String> = groupName != nil
        ? Set(readFolderApps(BASE.appendingPathComponent(groupName!)).map(\.name))
        : []
    var chosen: [URL] = []

    print("\n共 \(installed.count) 个已安装 App。先输关键词缩小范围，再敲序号多选（如 1 或 1,3 或 2-4）。")
    while true {
        let kw = ask("关键词过滤（回车=全部，q=完成选择）")
        if kw.lowercased() == "q" { return chosen }
        let cands = installed.filter { kw.isEmpty || $0.name.lowercased().contains(kw.lowercased()) }
        if cands.isEmpty {
            print("  没有匹配「\(kw)」的 App，换个关键词")
            continue
        }

        var page = 0
        while true {
            let lo = page * PAGE_SIZE
            let chunk = Array(cands[lo..<min(lo + PAGE_SIZE, cands.count)])
            for (i, c) in chunk.enumerated() {
                var tag = ""
                if chosen.contains(where: { $0.path == c.url.path }) {
                    tag = "✓已选"
                } else if exclude.contains(c.name) {
                    tag = "·已在该组"
                }
                print("  \(String(format: "%3d", lo + i + 1)). \(c.name)  \(tag)")
            }
            let total = cands.count
            let hi = min(lo + PAGE_SIZE, total)
            let nav = hi < total ? "，n=下一页" : ""
            let sel = ask("选择（\(lo + 1)-\(hi)/\(total)\(nav)，k=重新过滤，q=完成）")
            let low = sel.lowercased()
            if low == "q" { return chosen }
            if sel.isEmpty {
                if !chosen.isEmpty { return chosen }
                print("  还没选任何 App。输序号选择，或敲 q 取消。")
                continue
            }
            if low == "k" { break }              // 回到关键词输入
            if low == "n" && hi < total { page += 1; continue }
            if low == "p" && page > 0 { page -= 1; continue }

            guard let picks = parseSelection(sel, total) else {
                print("  输入无效：如 1 或 1,3 或 2-4")
                continue
            }
            for i in picks.sorted() {
                let (n, p) = cands[i]
                if exclude.contains(n) {
                    print("  · 「\(n)」已在该组，跳过")
                } else if !chosen.contains(where: { $0.path == p.path }) {
                    chosen.append(p)
                    print("  ✓ 已选 \(n)（共 \(chosen.count) 个）")
                }
            }
        }
    }
}
