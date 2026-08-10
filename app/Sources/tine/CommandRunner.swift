import Foundation

/// `run` is called on the main thread; `cache`/`inflight` must stay lock-guarded — the background queue mutates them too.
enum CommandRunner {
    private static var cache: [String: (output: String, at: Date)] = [:]
    private static var inflight: Set<String> = []
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "dev.gustaf.tine.generator", attributes: .concurrent)
    private static let ttl: TimeInterval = 3
    private static let grace: TimeInterval = 0.5

    static var onRefresh: (() -> Void)?

    /// Without this, a GUI-launched app only sees launchd's minimal PATH and generators
    /// shelling to Homebrew/pyenv/npm tools fail.
    private static var _shellPath: String?
    static func setShellPath(_ path: String) {
        lock.lock(); _shellPath = path.isEmpty ? nil : path; lock.unlock()
    }
    static func shellPath() -> String? {
        lock.lock(); defer { lock.unlock() }; return _shellPath
    }

    static var isLoading: Bool {
        lock.lock(); defer { lock.unlock() }; return !inflight.isEmpty
    }

    private static func encode(stdout: String, stderr: String, exitCode: Int32) -> String {
        let obj: [String: Any] = ["stdout": stdout, "stderr": stderr, "exitCode": Int(exitCode)]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"stdout":"","stderr":"","exitCode":1}"#
    }

    static func run(_ inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let executable = input["executable"] as? String, !executable.isEmpty
        else { return encode(stdout: "", stderr: "tine: bad command input", exitCode: 1) }

        let args = input["args"] as? [String] ?? []
        let cwd = input["workingDirectory"] as? String ?? ""
        let env = input["environment"] as? [String: String] ?? [:]
        let timeoutMs = input["timeout"] as? Double
        let key = "\(cwd)\u{1f}\(executable)\u{1f}\(args.joined(separator: "\u{1f}"))"

        lock.lock()
        let hit = cache[key]
        let dup = inflight.contains(key)
        if !dup { inflight.insert(key) }
        lock.unlock()

        if let hit, Date().timeIntervalSince(hit.at) < ttl {
            if !dup { lock.lock(); inflight.remove(key); lock.unlock() }
            return hit.output
        }

        if !dup {
            queue.async {
                // Must run on every exit path, or the leaked marker blocks this key forever.
                defer { lock.lock(); inflight.remove(key); lock.unlock() }
                let output = execute(executable: executable, args: args, cwd: cwd,
                                     env: env, timeoutMs: timeoutMs)
                let result = encode(stdout: output.stdout, stderr: output.stderr,
                                    exitCode: output.exitCode)
                lock.lock()
                let prev = cache[key]?.output
                cache[key] = (result, Date())
                if cache.count > 128 {
                    cache = cache.filter { Date().timeIntervalSince($0.value.at) < ttl }
                }
                lock.unlock()
                if result != prev, let refresh = onRefresh {
                    DispatchQueue.main.async(execute: refresh)
                }
            }
        }
        return hit?.output ?? encode(stdout: "", stderr: "", exitCode: 0)
    }

    /// Blocking — call off the main thread, or this freezes the UI.
    static func runOnce(executable: String, args: [String], timeoutMs: Double) -> Output {
        execute(executable: executable, args: args, cwd: "", env: [:], timeoutMs: timeoutMs)
    }

    typealias Output = (stdout: String, stderr: String, exitCode: Int32)

    private static func execute(executable: String, args: [String], cwd: String,
                                env: [String: String], timeoutMs: Double?) -> Output {
        var environment = ProcessInfo.processInfo.environment
        // Order matters: applying `env` after this lets a generator's own PATH override shellPath's.
        if let path = shellPath() { environment["PATH"] = path }
        for (k, v) in env { environment[k] = v }

        let child: Child
        do {
            child = try spawn(argv: ["/usr/bin/env", executable] + args,   // resolve via PATH
                              env: environment.map { "\($0)=\($1)" }, cwd: cwd)
        } catch {
            return ("", "\(error)", 127)
        }

        // 20s caps a spec's own requested timeout — remove it and a bad spec can hang a generator indefinitely.
        let requested = timeoutMs.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000.0 : nil }
        let timeout = min(requested ?? 2.0, 20.0)
        let start = DispatchTime.now()
        // SIGKILL escalation is required: a child can ignore SIGTERM and wedge the read forever.
        let term = DispatchWorkItem { child.signal(SIGTERM) }
        let kill9 = DispatchWorkItem { child.signal(SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: start + timeout, execute: term)
        DispatchQueue.global().asyncAfter(deadline: start + timeout + grace, execute: kill9)

        // Must drain stdout/stderr concurrently: sequential draining deadlocks if a
        // child fills the stderr pipe buffer without closing stdout.
        let readDeadline = start + timeout + grace * 2
        var status: Int32 = 0
        let reaper = DispatchWorkItem { status = child.reap() }
        queue.async(execute: reaper)
        var err = Data()
        let errDrain = DispatchWorkItem { err = drain(child.errFD, until: readDeadline) }
        queue.async(execute: errDrain)
        let out = drain(child.outFD, until: readDeadline)
        errDrain.wait()
        reaper.wait()
        term.cancel()
        kill9.cancel()

        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), status)
    }

    /// Must run in its own process group — without it, work the child backgrounded
    /// escapes our signals and holds the pipe open forever.
    private final class Child {
        let outFD: Int32
        let errFD: Int32
        private let pid: pid_t
        private var reaped = false
        private let lock = NSLock()

        init(pid: pid_t, outFD: Int32, errFD: Int32) {
            self.pid = pid
            self.outFD = outFD
            self.errFD = errFD
        }

        func signal(_ sig: Int32) {
            lock.lock(); defer { lock.unlock() }
            if !reaped { kill(-pid, sig) } // once reaped, the pid may already be recycled
        }

        /// waitid WNOWAIT, then kill(-pgid), then waitpid: the pid must not be reaped
        /// before the group kill lands, or it may already be recycled by then.
        func reap() -> Int32 {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            lock.lock(); kill(-pid, SIGKILL); reaped = true; lock.unlock()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 {
                if errno != EINTR { return 127 }
            }
            return status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
        }
    }

    private struct SpawnFailure: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "tine: \(String(cString: strerror(code)))" }
    }

    /// Must stay `posix_spawn`, not `Process` — only it can put the child in its own process group.
    private static func spawn(argv: [String], env: [String], cwd: String) throws -> Child {
        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { throw SpawnFailure(code: errno) }
        guard pipe(&errFDs) == 0 else {
            let code = errno
            close(outFDs[0]); close(outFDs[1])
            throw SpawnFailure(code: code)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], STDERR_FILENO)
        if !cwd.isEmpty { posix_spawn_file_actions_addchdir(&actions, cwd) }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // Without CLOEXEC_DEFAULT, another concurrent run's pipe fd leaks into this child.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attrs, 0)

        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer { for p in cArgv + cEnv { free(p) } }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, argv[0], &actions, &attrs, cArgv, cEnv)
        close(outFDs[1])
        close(errFDs[1])
        guard code == 0 else {
            close(outFDs[0]); close(errFDs[0])
            throw SpawnFailure(code: code)
        }
        return Child(pid: pid, outFD: outFDs[0], errFD: errFDs[0])
    }

    /// Must stay Dispatch I/O, not `readDataToEndOfFile` — that blocks its thread for as long as the writer lives.
    private static func drain(_ fd: Int32, until deadline: DispatchTime) -> Data {
        let reader = DispatchQueue(label: "dev.gustaf.tine.generator.read")
        let done = DispatchSemaphore(value: 0)
        var buffer = Data()
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: reader) { _ in
            close(fd)
            done.signal()
        }
        channel.read(offset: 0, length: Int.max, queue: reader) { finished, data, _ in
            if let data { buffer.append(contentsOf: data) }
            if finished { channel.close() }
        }
        if done.wait(timeout: deadline) == .timedOut {
            channel.close(flags: .stop)
            done.wait()
        }
        return reader.sync { buffer }
    }
}
