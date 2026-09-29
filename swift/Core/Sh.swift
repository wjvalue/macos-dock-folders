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
        // 输入走后台线程 + 裸 write(2)：子进程可能提前退出（比如 defaults import
        // 拒绝输入），往断掉的管道写会 EPIPE —— FileHandle.write 会抛 ObjC 异常
        // （Swift 接不住，整个进程崩），裸 write 只返回 -1，随它去。
        // Python 的 subprocess.communicate 在另一条线程里干的就是这件事；
        // CPython 启动时就 SIG_IGN 了 SIGPIPE，这里对齐。
        DispatchQueue.global().async {
            signal(SIGPIPE, SIG_IGN)
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard var ptr = buf.baseAddress else { return }
                var remaining = buf.count
                while remaining > 0 {
                    let n = write(ip.fileHandleForWriting.fileDescriptor, ptr, remaining)
                    if n <= 0 { break }   // EPIPE / EBADF：子进程先走了，随它去
                    ptr += n
                    remaining -= n
                }
            }
            try? ip.fileHandleForWriting.close()
        }
    }

    // ⚠️ 两条管道必须**并发**排水，不能串行：父进程卡在等 stdout EOF 时，子进程
    // 若已把 stderr 写满 64KB 管道缓冲（swiftc 对坏源码的诊断动辄几 MB）就会被
    // 写阻塞 —— 子进程不退出、stdout 永不 EOF，整条命令挂死。（2026-09-29 修：
    // 原来是先读 stdout 再读 stderr 的串行 readDataToEndOfFile。）
    let group = DispatchGroup()
    let drain = DispatchQueue(label: "local.dockgroup.sh-drain", attributes: .concurrent)
    var outData = Data(), errData = Data()
    group.enter()
    drain.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    drain.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.wait()
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
