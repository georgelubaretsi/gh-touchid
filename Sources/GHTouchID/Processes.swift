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
