import Darwin
import Foundation

// Every program gh-touchid starts or becomes is started here, and only here are its path, arguments and environment
// turned into C strings. A C string ends at its first NUL, so a NUL inside a Swift string (one that came in JSON, say)
// would cut the argument short after every check had read it whole: a check reads `auth\0x` as no command it knows,
// and gh receives `auth`. Each helper refuses such a string before converting anything, so no launch can skip the
// refusal; scripts/check-launch.sh fails the lint when another file starts a program itself.

/// What in a launch a program could not receive whole, because it contains a NUL: the program, `argument N` (argv[N],
/// argv[0] being the program) or an environment variable named by what precedes its first `=`; nil when nothing does.
/// Values are never named, since they may hold tokens.
private func unreceivable(_ executable: String, _ arguments: [String], environment: [String]) -> String? {
    if executable.utf8.contains(0) {
        return "the program's path"
    }
    if let index = arguments.firstIndex(where: { $0.utf8.contains(0) }) {
        return "argument \(index + 1)"
    }
    if let entry = environment.first(where: { $0.utf8.contains(0) }) {
        let name = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return "the environment variable \(printable(String(name)))"
    }
    return nil
}

/// Throws when `unreceivable` finds a NUL.
private func refuseNUL(_ executable: String, _ arguments: [String], environment: [String]) throws {
    if let what = unreceivable(executable, arguments, environment: environment) {
        throw ToolError.input("\(what) contains a NUL character, which a program cannot receive: remove it")
    }
}

/// `NAME=value` entries of `environment`, as a program receives them.
private func environmentEntries(_ environment: [String: String]) -> [String] {
    environment.map { "\($0.key)=\($0.value)" }
}

/// Copies of `strings` as C strings, followed by the NULL that ends an argv or envp list. The caller frees each.
private func cStringList(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
    strings.map { strdup($0) } + [nil]
}

/// Starts `executable` with `arguments` (argv[0] is its path) and `environment`, sharing only stdin, stdout and stderr
/// (or `streams`, descriptors put in their place), with every signal at its default action and none blocked; stopped
/// before its first instruction when `suspended`, until it gets SIGCONT. With `searchPath`, a name without a slash is
/// looked up on PATH.
func spawn(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    suspended: Bool,
    streams: [Int32]? = nil,
    searchPath: Bool = false
) throws -> pid_t {
    let entries = environmentEntries(environment)
    try refuseNUL(executable, arguments, environment: entries)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    if suspended {
        flags |= POSIX_SPAWN_START_SUSPENDED
    }
    posix_spawnattr_setflags(&attributes, Int16(flags))
    var defaults = sigset_t()
    sigfillset(&defaults)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        if let streams {
            posix_spawn_file_actions_adddup2(&actions, streams[Int(descriptor)], descriptor)
        } else {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
    }
    var argv = cStringList([executable] + arguments)
    defer { argv.forEach { free($0) } }
    var envp = cStringList(entries)
    defer { envp.forEach { free($0) } }
    var pid: pid_t = 0
    let started = searchPath
        ? posix_spawnp(&pid, executable, &actions, &attributes, &argv, &envp)
        : posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
    guard started == 0 else {
        guard !searchPath else {
            throw ToolError.input("cannot run \(executable): \(String(cString: strerror(started)))")
        }
        throw ToolError.missingGitHubCLI(executable)
    }
    return pid
}

/// Waits for the child `pid` and returns its exit status, or 128 plus the signal that ended it.
func waitForExit(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        guard errno == EINTR else {
            return 1
        }
    }
    let signal = status & 0x7F
    return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
}

/// Starts the agent, `executable` with `arguments` (argv[0] is its path), as its own session, detached from the
/// terminal, with stdin, stdout and stderr on /dev/null and no environment but `environment` (`NAME=value` entries).
func spawnAgentProcess(_ executable: String, _ arguments: [String], environment: [String]) throws -> pid_t {
    try refuseNUL(executable, arguments, environment: environment)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    var argv = cStringList([executable] + arguments)
    defer { argv.forEach { free($0) } }
    var envp = cStringList(environment)
    defer { envp.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
    guard status == 0 else {
        throw ToolError.agent("cannot start the agent: \(String(cString: strerror(status)))")
    }
    return pid
}

/// Replaces this process with `executable`, given `arguments` (argv[0] is `executable`) and this process's
/// environment; with `searchPath`, a name without a slash is looked up on PATH. Returns only when that fails, with
/// the reason.
func replaceProcess(with executable: String, arguments: [String], searchPath: Bool) throws -> String {
    try refuseNUL(executable, arguments, environment: [])
    var argv = cStringList([executable] + arguments)
    defer { argv.forEach { free($0) } }
    if searchPath {
        execvp(executable, &argv)
    } else {
        execv(executable, &argv)
    }
    return String(cString: strerror(errno))
}

/// Runs `executable` with `arguments` through Foundation's Process and waits for it: its exit status (or the signal
/// that ended it), whether it exited rather than being ended by a signal, and its stdout read to the end when
/// `captureOutput`. A nil `environment`, `standardInput` or `standardError` is gh-touchid's own, as is stdout without
/// `captureOutput`. With `promptly` it waits on the termination handler, since waitUntilExit polls and adds ~70 ms;
/// without, it waits with waitUntilExit, which also runs the current run loop meanwhile. Nil when the program cannot
/// start or a string it would receive contains a NUL.
private func runProcess(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String]? = nil,
    standardInput: FileHandle? = nil,
    standardError: FileHandle? = nil,
    captureOutput: Bool,
    promptly: Bool
) -> (status: Int32, exitedNormally: Bool, output: Data)? {
    guard unreceivable(executable.path, arguments, environment: environment.map(environmentEntries) ?? []) == nil else {
        return nil
    }
    let process = Process()
    let exited = DispatchSemaphore(value: 0)
    if promptly {
        process.terminationHandler = { _ in exited.signal() }
    }
    process.executableURL = executable
    process.arguments = arguments
    if let environment {
        process.environment = environment
    }
    if let standardInput {
        process.standardInput = standardInput
    }
    let output = captureOutput ? Pipe() : nil
    if let output {
        process.standardOutput = output
    }
    if let standardError {
        process.standardError = standardError
    }
    guard (try? process.run()) != nil else {
        return nil
    }
    let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    if promptly {
        exited.wait()
    } else {
        process.waitUntilExit()
    }
    return (process.terminationStatus, process.terminationReason == .exit, data)
}

/// Runs `executable` with `arguments` and `environment`, stdin and stderr on /dev/null, and returns its exit status,
/// whether it exited rather than being ended by a signal, and its stdout; nil when it cannot start or a string it would
/// receive contains a NUL.
func runCapturingOutput(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String]
) -> (status: Int32, exitedNormally: Bool, output: Data)? {
    runProcess(
        executable,
        arguments,
        environment: environment,
        standardInput: FileHandle.nullDevice,
        standardError: FileHandle.nullDevice,
        captureOutput: true,
        promptly: true
    )
}

/// Runs `executable` with `arguments`, gh-touchid's own stdin and environment, and returns its exit status and stdout;
/// its stderr goes to gh-touchid's when `showErrors`, else to /dev/null. Nil when it cannot start or an argument
/// contains a NUL.
func runReadingOutput(_ executable: URL, _ arguments: [String], showErrors: Bool) -> (status: Int32, output: Data)? {
    runProcess(
        executable,
        arguments,
        standardError: showErrors ? FileHandle.standardError : FileHandle.nullDevice,
        captureOutput: true,
        promptly: false
    ).map { ($0.status, $0.output) }
}

/// Runs `executable` with `arguments`, sharing gh-touchid's streams and environment, and waits for it; false when it
/// cannot start or an argument contains a NUL.
@discardableResult
func runAndWait(_ executable: URL, _ arguments: [String]) -> Bool {
    runProcess(executable, arguments, captureOutput: false, promptly: false) != nil
}
