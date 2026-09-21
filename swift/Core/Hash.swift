// swift/Core/Hash.swift
//
// MD5 / SHA256 的小包装。
//
// 用 CryptoKit —— 它是 macOS 10.15+ 的系统框架，不算第三方依赖。
// 这里要它是因为两个 Python 侧的行为要照抄：
//   · `hashlib.md5(路径)[:4]` 决定 Dock tile 的 GUID
//   · `hashlib.sha256(源码).hexdigest()` 是启动器二进制的缓存判据
// 判据一旦算错，要么每次都重编译，要么该重编译时用了旧二进制
// （后者更糟：改完 UI 跑 rebuild，Dock 上点开还是旧面板，而 rebuild 照样报成功）。

import CryptoKit
import Foundation

/// `hashlib.md5(文本).digest()[:n]` —— 前 n 个字节。
func md5Prefix(_ text: String, _ n: Int) -> [UInt8] {
    Array(Insecure.MD5.hash(data: Data(text.utf8)).prefix(n))
}

/// `hashlib.sha256(数据).hexdigest()`
func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(_ text: String) -> String {
    sha256Hex(Data(text.utf8))
}
