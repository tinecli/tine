import Foundation

/// Runs the shell commands that Fig generators request (git branch, ls, …).
/// Synchronous with a timeout — fits the engine's synchronous suggestion pass.
/// Input/output are JSON to keep the JS<->Swift boundary simple.
enum CommandRunner {
    // Fig's generator cache is stale-while-revalidate: it re-runs the generator
    // every keystroke. This bridge used to run that subprocess *synchronously on
    // the main thread*, so the first call for a new command (e.g. `git branch`
    // when you type the space after `git checkout`) blocked the keystroke.
    //
    // Now the subprocess runs on a background queue: a fresh cache hit returns
    // immediately, a miss returns the stale value (or empty) at once and refreshes
    // the cache in the background, so the next keystroke has it. In-flight commands
    // are deduped so rapid keystrokes don't spawn duplicate runs. `run` is called
    // on the main thread (from the engine); `cache`/`inflight` are lock-guarded
    // because the background work mutates them.
    private static var cache: [String: (output: String, at: Date)] = [:]
    private static var inflight: Set<String> = []
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "dev.gustaf.tine.generator", attributes: .concurrent)
    private static let ttl: TimeInterval = 3
    /// How long a timed-out child gets to honour SIGTERM before SIGKILL, and again
    /// to close its pipes before the reads give up. Short: a wedged generator has
    /// nothing left to say, and the panel is waiting on it.
    private static let grace: TimeInterval = 0.5

    /// Called (on the main thread) when a background refresh produced *new* output,
    /// so the app can re-run the current suggestion and surface late generator
    /// results without waiting for the next keystroke.
    static var onRefresh: (() -> Void)?

    /// The shell's PATH (sent by tine.zsh). A GUI-launched app gets only the
    /// minimal launchd PATH, so generators shelling out to Homebrew/pyenv/npm
    /// tools (aws, gh, docker, …) fail without this.
    private static var _shellPath: String?
    static func setShellPath(_ path: String) {
        lock.lock(); _shellPath = path.isEmpty ? nil : path; lock.unlock()
    }
    private static func shellPath() -> String? {
        lock.lock(); defer { lock.unlock() }; return _shellPath
    }

    /// True while a generator subprocess is running in the background — the last
    /// suggestion pass asked for output that wasn't cached yet. Drives the panel's
    /// loading spinner.
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
            // Fresh: also clear the inflight marker we may have just set.
            if !dup { lock.lock(); inflight.remove(key); lock.unlock() }
            return hit.output
        }

        // Stale or missing: refresh off the main thread so the keystroke never
        // blocks. Return the stale value if we have one, else an empty success.
        if !dup {
            queue.async {
                // Clearing the marker must survive every path out of here: a leaked
                // marker pins `isLoading` on and blocks that key from running again.
                defer { lock.lock(); inflight.remove(key); lock.unlock() }
                let result = execute(executable: executable, args: args, cwd: cwd,
                                     env: env, timeoutMs: timeoutMs)
                lock.lock()
                let prev = cache[key]?.output
                cache[key] = (result, Date())
                if cache.count > 128 {
                    cache = cache.filter { Date().timeIntervalSince($0.value.at) < ttl }
                }
                lock.unlock()
                // New data the current suggestion pass didn't have — ask the app to
                // re-run it so late results (e.g. a fresh `ls` after `cd`) appear.
                if result != prev, let refresh = onRefresh {
                    DispatchQueue.main.async(execute: refresh)
                }
            }
        }
        return hit?.output ?? encode(stdout: "", stderr: "", exitCode: 0)
    }

    private static func execute(executable: String, args: [String], cwd: String,
                                env: [String: String], timeoutMs: Double?) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")   // resolve via PATH
        proc.arguments = [executable] + args
        if !cwd.isEmpty { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        // Use the shell's PATH so Homebrew/pyenv/npm tools resolve; a generator's
        // own env still wins if it sets PATH explicitly.
        if let path = shellPath() { environment["PATH"] = path }
        for (k, v) in env { environment[k] = v }
        proc.environment = environment

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            return encode(stdout: "", stderr: "\(error)", exitCode: 127)
        }

        // A spec's timeout is a request, not a cap: honour it up to 20 s — the
        // longest any shipped spec asks for. 2 s only when a spec asks for nothing.
        let requested = timeoutMs.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000.0 : nil }
        let timeout = min(requested ?? 2.0, 20.0)
        let start = DispatchTime.now()
        // SIGTERM is a request; a child that ignores it holds its stdout open and
        // wedges the read. Escalate to SIGKILL, which it cannot ignore.
        let term = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        let kill9 = DispatchWorkItem { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: start + timeout, execute: term)
        DispatchQueue.global().asyncAfter(deadline: start + timeout + grace, execute: kill9)

        // The reads need a deadline of their own, strictly after the SIGKILL: a
        // grandchild that inherited the write end keeps the pipe open even once
        // the child is dead, and would otherwise block here forever.
        // Both at once, sharing one deadline: a child that fills the stderr pipe
        // buffer blocks there and never closes stdout, so draining in sequence
        // would spend the whole deadline on stdout and lose stderr entirely.
        let readDeadline = start + timeout + grace * 2
        var err = Data()
        let errDrain = DispatchWorkItem { err = drain(errPipe, until: readDeadline) }
        queue.async(execute: errDrain)
        let out = drain(outPipe, until: readDeadline)
        errDrain.wait()
        proc.waitUntilExit()
        term.cancel()
        kill9.cancel()

        return encode(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitCode: proc.terminationStatus
        )
    }

    /// Reads a pipe to EOF, giving up at `deadline` with whatever arrived so far.
    /// Dispatch I/O rather than `readDataToEndOfFile` so an abandoned read releases
    /// its thread instead of blocking one for as long as the writer lives.
    private static func drain(_ pipe: Pipe, until deadline: DispatchTime) -> Data {
        let fd = dup(pipe.fileHandleForReading.fileDescriptor)
        guard fd >= 0 else { return Data() }
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
