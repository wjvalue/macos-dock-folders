// winlist — 列出屏幕上「Dock 分组启动器」的窗口号与位置
//
// 为什么要这个工具：验证面板 UI（材质深浅、四角圆角、窗口阴影）**只能靠真机截图**
// —— 离屏渲染看不到窗口阴影，毛玻璃还会退化成透明，用它判断材质会得出完全错误的
// 结论（踩过：hud 材质在离屏图里看着是深色，真机上其实是浅的）。
// 而截图需要窗口号：`screencapture -x -l <窗口号>` 或 `-R x,y,w,h`。
//
// CGWindowListCopyWindowInfo 里的 owner 名 = 启动器 bundle 的 CFBundleName
// = 分组名，所以能按名字过滤。面板的窗口层级恒为 101（NSWindow.Level.popUpMenu）。
//
// 编译：swiftc -O -o /tmp/winlist scripts/winlist.swift -framework Cocoa
// 用法：/tmp/winlist          列出所有面板层窗口
//       /tmp/winlist AI 办公   只列 owner 名含这些词的
//
// 典型用法（截一张「屏幕合成」的图，最接近肉眼所见）：
//   NUM=$(/tmp/winlist AI | head -1 | cut -f1)
//   screencapture -x -l "$NUM" /tmp/panel.png      # 窗口本体，不含阴影
//   screencapture -x -R 860,483,432,174 /tmp/panel.png   # 屏幕区域，含阴影和毛玻璃
import Cocoa

let filters = Array(CommandLine.arguments.dropFirst())
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []

func num(_ w: [String: Any], _ key: String) -> Int {
    (w[key] as? NSNumber)?.intValue ?? -1
}

var found = 0
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = num(w, kCGWindowLayer as String)
    // 不给过滤条件时，只认面板层（101）—— 免得把满屏普通窗口都列出来
    if filters.isEmpty ? (layer != 101)
                       : !filters.contains(where: { owner.localizedCaseInsensitiveContains($0) }) {
        continue
    }
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    func g(_ k: String) -> Int { (bounds[k] as? NSNumber)?.intValue ?? 0 }
    print("\(num(w, kCGWindowNumber as String))\tlayer=\(layer)\towner=\(owner)\t"
          + "bounds=\(g("X")),\(g("Y")) \(g("Width"))x\(g("Height"))")
    found += 1
}
if found == 0 {
    FileHandle.standardError.write(
        "没找到匹配的面板窗口（启动器可能没在跑）\n".data(using: .utf8)!)
}
