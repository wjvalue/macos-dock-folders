// swift/Core/Sh.swift
//
// 跑外部命令。对应 Python 的 `sh()`。
//
// 那边踩过一个坑值得照抄：**找不到可执行文件时不能抛异常**，返回失败结果就行 ——
// `dg doctor` 恰恰是在「环境不对劲」的时候才会被想起来的，它自己不能先崩
// （2026-09-21 修）。这里同样返回 status = -1。
//
// ⚠️ 读管道要在 waitUntilExit **之前** —— 反过来的话输出超过管道缓冲（64KB）
// 就会死锁。`defaults export` 的输出轻松超过这个量。

import Foundation

struct ProcResult {
    var status: Int32
    var out: Data
    var err: Data

    var ok: Bool { status == 0 }
    var text: String { String(data: out, encoding: .utf8) ?? "" }
    var errText: String { String(data: err, encoding: .utf8) ?? "" }
}

@discardableResult
func run(_ path: String, _ args: [String] = [], input: Data? = nil,
         cwd: URL? = nil) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let c = cwd { p.currentDirectoryURL = c }

    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe

    var inPipe: Pipe?
    if input != nil {
        let ip = Pipe()
        p.standardInput = ip
        inPipe = ip
    }

    do {
        try p.run()
    } catch {
        // 找不到可执行文件 —— 对应 Python sh() 里 catch FileNotFoundError 那支
        return ProcResult(status: -1, out: Data(),
                          err: Data("找不到可执行文件：\(path)".utf8))
    }

    if let ip = inPipe, let data = input {
        ip.fileHandleForWriting.write(data)
        ip.fileHandleForWriting.closeFile()
    }

    // 先读干净再等退出，避免管道写满导致死锁
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ProcResult(status: p.terminationStatus, out: outData, err: errData)
}

/// 只关心 stdout 文本时用这个（Python 里绝大多数调用也是这个用途）。
func runText(_ path: String, _ args: [String] = []) -> String {
    run(path, args).text
}

/// 对应 Python 的 `shutil.which` —— PATH 里找不到就返回 nil，不抛异常。
func which(_ tool: String) -> String? {
    let env = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    for dir in env.split(separator: ":") {
        let candidate = String(dir) + "/" + tool
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
