// swift/Core/Util.swift
//
// 几个「行为要和 Python 对齐」的小工具。

import Foundation

/// 对应 Python f-string 的 `{:<N}`：按**字符数**左对齐补齐。
/// 中文也算一个位置 —— 所以含中文的名字看起来会「不齐」，但这是原版行为，照抄。
/// （Python 的 `<` 格式符按字符数算，不是显示宽度。）
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// Python 的字符串比较按**码点**来；Swift 的 `String` `<` 用的是 Unicode
/// 规范化排序，中文和符号上可能给出不同结果。UTF-8 的字节序与码点序一致，
/// 拿它比最稳 —— 凡是 `sorted(glob(...))` 这类要和 Python 对齐的排序都要用它，
/// 否则名字一带中文顺序就错了。
func pyLess(_ a: String, _ b: String) -> Bool {
    Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
}

/// 对应 Python 的 `SystemExit("...")`。
///
/// 为什么要专门一个类型：`refresh_groups` 会**逐个分组**构建、把失败的分组
/// 「跳过」而不是让整个命令挂掉（比如某个分组的文件夹被删了，其它分组照常刷新）。
/// 用 `exit(1)` 就没法在中途捞回来，所以底层构建函数改成抛错，由调用方决定。
struct DgError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
