import Foundation

/// Downloads the completion spec pack (built + published by the tinecli/autocomplete
/// fork) at runtime and installs it to ~/.local/share/tine/specs — so specs update
/// without an app release.
@MainActor
final class SpecInstaller: ObservableObject {
    enum Status: Equatable {
        case idle, running, done(String), failed(String)
    }
    @Published var status: Status = .idle
    /// Cached from a background HEAD check, surfaced by `tine doctor`. Fails closed:
    /// stays false when GitHub is unreachable, so doctor never nags on a flaky network.
    @Published var updateAvailable = false

    /// Pinned HTTPS release asset, same trust root as the notarized app — never
    /// make this a user-configurable host.
    nonisolated static let packURL = URL(string:
        "https://github.com/tinecli/autocomplete/releases/download/specs/specs.tar.gz")!
    nonisolated static let specsDir = "\(NSHomeDirectory())/.local/share/tine/specs"
    /// Kept *beside*, not inside, specsDir: the install swap wipes specsDir, so a
    /// marker in it wouldn't survive.
    nonisolated static let markerPath = "\(NSHomeDirectory())/.local/share/tine/.pack-etag"

    var statusLine: String {
        switch status {
        case .idle: return "idle"
        case .running: return "running"
        case .done(let m): return "done:\(m.socketSafe)"
        case .failed(let m): return "failed:\(m.socketSafe)"
        }
    }

    private var timer: Timer?

    /// Fires on the main thread after a successful install.
    var onInstalled: (() -> Void)?

    nonisolated static func isInstalled() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: specsDir))?
            .contains { $0.hasSuffix(".js") } ?? false
    }

    /// Unique top-level entries (one `foo.js` or one `foo/` dir each) — NOT the same as
    /// index.json's entry count, which lists one per spec *file* and fragments `aws`
    /// alone into hundreds.
    nonisolated static func installedCount() -> Int { commandCount(in: specsDir) }

    nonisolated static func commandCount(in dir: String) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        var clis = Set<String>()
        for e in entries {
            if e.hasSuffix(".js") {
                clis.insert(String(e.dropLast(3)))
            } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: "\(dir)/\(e)", isDirectory: &isDir), isDir.boolValue {
                    clis.insert(e)
                }
            }
        }
        return clis.count
    }

    /// The fork ships ~730 commands, so anything near zero means a truncated or empty
    /// tarball — which would otherwise wipe the installed specs down to the app's own builtins.
    nonisolated static let minimumPackCommands = 100

    /// Must run before the installed pack is touched or the ETag recorded: a bad
    /// download this rejects should leave the user's specs untouched and get retried
    /// on the next check.
    nonisolated static func validate(pack dir: String) throws {
        guard FileManager.default.fileExists(atPath: "\(dir)/index.json") else {
            throw NSError(domain: "tine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "spec pack has no index — keeping the installed one"])
        }
        let count = commandCount(in: dir)
        guard count > minimumPackCommands else {
            throw NSError(domain: "tine", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "spec pack looks incomplete (\(count) commands) — keeping the installed one"])
        }
    }

    /// Skips the download when the installed pack's ETag already matches the fork's.
    /// `announce` posts a notification once the swap lands — for installs the user
    /// didn't ask for, so ~730 CLIs never change underneath them silently.
    func install(announce: Bool = false) {
        guard status != .running else { return }
        status = .running
        Task {
            do {
                let remote = try? await Self.remoteETag()
                if let remote, remote == Self.storedETag(), Self.isInstalled() {
                    self.updateAvailable = false
                    self.status = .done("specs up to date (\(Self.installedCount()) commands)")
                    return
                }
                let count = try await Self.downloadAndInstall()
                self.updateAvailable = false
                self.status = .done("specs updated (\(count) commands)")
                self.onInstalled?()
                if announce {
                    UpdateNotice.post("Completion specs updated", "\(count) commands are ready.")
                }
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    enum UpdateAction: Equatable { case none, adoptBaseline, flag, autoInstall }

    nonisolated static func updateAction(remote: String?, stored: String?,
                                         autoInstall: Bool) -> UpdateAction {
        // Fails closed: no ETag means no network, which is never a reason to act.
        guard let remote else { return .none }
        // No stored marker means this installed before ETag tracking existed — adopt
        // the current pack as the baseline instead of flagging every such user once.
        guard let stored else { return .adoptBaseline }
        guard remote != stored else { return .none }
        return autoInstall ? .autoInstall : .flag
    }

    /// Checks now, then daily — a launch-only check would leave a long-running
    /// session (the agent stays up for days) on a stale pack forever.
    func startChecking() {
        checkForUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdate() }
        }
    }

    func checkForUpdate() {
        Task {
            guard Self.isInstalled() else { return }
            let remote = try? await Self.remoteETag()
            switch Self.updateAction(remote: remote, stored: Self.storedETag(),
                                     autoInstall: TineConfig.load().autoUpdateSpecs) {
            case .none:
                break
            case .adoptBaseline:
                try? remote?.write(toFile: Self.markerPath, atomically: true, encoding: .utf8)
            case .flag:
                self.updateAvailable = true
            case .autoInstall:
                self.install(announce: true)
            }
        }
    }

    /// Content-derived and stable, so it changes exactly when the fork republishes.
    /// Nil on any non-200 or network failure.
    nonisolated private static func remoteETag() async throws -> String? {
        var req = URLRequest(url: packURL)
        req.httpMethod = "HEAD"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return http.value(forHTTPHeaderField: "Etag")
    }

    nonisolated private static func storedETag() -> String? {
        try? String(contentsOfFile: markerPath, encoding: .utf8)
    }

    /// The pack only re-merges builtin-specs/ on download, so without this an app
    /// update that changes it (e.g. new `tine` subcommands) would never reach an
    /// already-installed pack.
    nonisolated static func refreshBuiltins() {
        guard isInstalled() else { return }
        mergeBuiltins(into: specsDir)
    }

    nonisolated private static func downloadAndInstall() async throws -> Int {
        let fm = FileManager.default
        let (tmp, resp) = try await URLSession.shared.download(from: packURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "tine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "spec download failed (HTTP error)"])
        }

        let staging = NSTemporaryDirectory() + "tine-specs-\(UUID().uuidString)"
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: staging) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tmp.path, "-C", staging]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw NSError(domain: "tine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "spec extract failed"])
        }

        mergeBuiltins(into: staging)
        try validate(pack: staging)

        try fm.createDirectory(atPath: (specsDir as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try? fm.removeItem(atPath: specsDir)
        try fm.moveItem(atPath: staging, toPath: specsDir)
        if let etag = http.value(forHTTPHeaderField: "Etag") {
            try? etag.write(toFile: markerPath, atomically: true, encoding: .utf8)
        }
        return installedCount()
    }

    /// Registers the copied specs in index.json too, so they resolve like pack specs.
    nonisolated private static func mergeBuiltins(into dir: String) {
        let fm = FileManager.default
        guard let res = Bundle.main.resourcePath else { return }
        let builtin = "\(res)/builtin-specs"
        guard let files = try? fm.contentsOfDirectory(atPath: builtin) else { return }

        var names: [String] = []
        for f in files where f.hasSuffix(".js") {
            let dest = "\(dir)/\(f)"
            try? fm.removeItem(atPath: dest)   // overwrite: track the running app version
            try? fm.copyItem(atPath: "\(builtin)/\(f)", toPath: dest)
            names.append(String(f.dropLast(3)))
        }
        guard !names.isEmpty else { return }

        let idxPath = "\(dir)/index.json"
        guard let data = fm.contents(atPath: idxPath),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        var comps = (obj["completions"] as? [String]) ?? []
        for n in names where !comps.contains(n) { comps.append(n) }
        obj["completions"] = comps
        if obj["diffVersionedCompletions"] == nil { obj["diffVersionedCompletions"] = [String]() }
        if let out = try? JSONSerialization.data(withJSONObject: obj) {
            try? out.write(to: URL(fileURLWithPath: idxPath))
        }
    }
}
