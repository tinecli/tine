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
                let result = execute(executable: executable, args: args, cwd: cwd,
                                     env: env, timeoutMs: timeoutMs)
                lock.lock()
                let prev = cache[key]?.output
                cache[key] = (result, Date())
                inflight.remove(key)
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

        let timeout = min(timeoutMs.map { $0 / 1000.0 } ?? 2.0, 2.0)
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()

        return encode(
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
    }
}
