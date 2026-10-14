import Darwin
import Foundation

/// Absolute path of a process's executable, or nil when it cannot be read.
func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : nil
}

/// This program's own executable; daemon and clients trust each other only when theirs are the same.
let ownExecutablePath: String? = executablePath(getpid())

func processName(_ pid: pid_t) -> String {
    executablePath(pid).map { ($0 as NSString).lastPathComponent } ?? "?"
}

private func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
        return nil
    }
    return info
}

func parentProcess(_ pid: pid_t) -> pid_t? {
    processInfo(pid).map { pid_t($0.pbi_ppid) }
}

/// When a process started; with its pid it names one process even after the pid is reused.
struct ProcessStart: Equatable {
    let seconds: UInt64
    let microseconds: UInt64

    var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1_000_000)
    }
}

/// Start of a live process; nil when it is gone or a zombie.
func processStart(_ pid: pid_t) -> ProcessStart? {
    guard let info = processInfo(pid), info.pbi_status != 5 /* SZOMB */ else {
        return nil
    }
    return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
}

/// The command-line arguments of a process of this user (`KERN_PROCARGS2`), argv[0] first; nil when unreadable.
func processArguments(_ pid: pid_t) -> [String]? {
    var name: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var limit: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&name, 2, &limit, &size, nil, 0) == 0, limit > 0 else {
        return nil
    }
    // argc, the executable path, NUL padding, then argc NUL-terminated arguments (then the environment)
    var buffer = [UInt8](repeating: 0, count: Int(limit))
    name = [CTL_KERN, KERN_PROCARGS2, pid]
    size = buffer.count
    guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 {
        index += 1
    }
    while index < size, buffer[index] == 0 {
        index += 1
    }
    var arguments: [String] = []
    while arguments.count < count, index < size {
        let start = index
        while index < size, buffer[index] != 0 {
            index += 1
        }
        arguments.append(String(decoding: buffer[start ..< index], as: UTF8.self))
        index += 1
    }
    return arguments
}

let shellNames: Set<String> = ["sh", "bash", "zsh", "dash"]

/// Whether `pid` is a shell that only runs a command (`-c`) or a script, rather than an interactive one.
func isNonInteractiveShell(_ pid: pid_t) -> Bool {
    guard shellNames.contains(processName(pid)), let arguments = processArguments(pid) else {
        return false
    }
    var interactive = false
    var command = false
    var script = false
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" || argument == "-" {
            script = index + 1 < arguments.count
            break
        }
        if argument.hasPrefix("--") {
            if argument == "--rcfile" || argument == "--init-file" {
                index += 1
            }
        } else if argument.hasPrefix("-") || argument.hasPrefix("+") {
            let letters = argument.dropFirst()
            if argument.hasPrefix("-") {
                interactive = interactive || letters.contains("i")
                command = command || letters.contains("c")
            }
            if letters.contains("o") || letters.contains("O") {
                index += 1 // -o option, -O shopt_option
            }
        } else {
            script = true // a script, or the command of -c
            break
        }
        index += 1
    }
    return !interactive && (command || script)
}

/// The process a session belongs to: the parent of `gh-touchid session`, or further up past shells that only run a
/// command or a script, so that a program running `sh -c 'gh-touchid session'` registers itself. An interactive
/// shell is a session root itself.
func sessionRoot(of pid: pid_t) -> pid_t? {
    guard var root = parentProcess(pid), root > 1 else {
        return nil
    }
    while isNonInteractiveShell(root), let parent = parentProcess(root), parent > 1 {
        root = parent
    }
    return root
}

/// `pid` and its ancestors, nearest first, without launchd; at most 64.
func lineage(_ pid: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    var current: pid_t? = pid
    while let process = current, process > 1, result.count < 64 {
        result.append(process)
        current = parentProcess(process)
    }
    return result
}

/// `gh-touchid[812] < git[810] < zsh[790] < bun[700]`: who asked, and who started it.
func processChain(_ pid: pid_t) -> String {
    let parts = lineage(pid).prefix(6).map { "\(processName($0))[\($0)]" }
    return parts.isEmpty ? "unknown process" : parts.joined(separator: " < ")
}

/// The peer of a local socket (`LOCAL_PEERPID` at level `SOL_LOCAL`, from sys/un.h).
func peerProcess(_ fd: Int32) -> pid_t? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, 0, 0x002, &pid, &length) == 0, pid > 0 else {
        return nil
    }
    return pid
}
