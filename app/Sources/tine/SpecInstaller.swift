import Foundation

@MainActor
final class SpecInstaller: ObservableObject {
    enum Status: Equatable {
        case idle, running, done(String), failed(String)
    }
    @Published private var jobState = JobState<Status>(.idle)
    var status: Status { jobState.status }
    /// Fails closed on a network error — never flip this to fail-open, or doctor nags on flaky Wi-Fi.
    @Published var updateAvailable = false

    /// Never make this user-configurable — it's the trust root for what tine installs.
    nonisolated static let packURL = URL(string:
        "https://github.com/tinecli/autocomplete/releases/download/specs/specs.tar.gz")!
    nonisolated static let specsDir = "\(NSHomeDirectory())/.local/share/tine/specs"
    /// Must stay outside specsDir: the install swap wipes specsDir, and a marker inside it wouldn't survive.
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

    var onInstalled: (() -> Void)?

    nonisolated static func isInstalled() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: specsDir))?
            .contains { $0.hasSuffix(".js") } ?? false
    }

    /// Not index.json's entry count — that's one per spec *file* and fragments `aws` into hundreds.
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

    nonisolated static let minimumPackCommands = 100

    /// Must run before the installed pack is touched or the ETag recorded, or a bad download wipes good specs.
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

    func install(announce: Bool = false) {
        guard case .started(let job) = jobState.start("spec install", status: .running)
        else { return }
        Task {
            do {
                let remote = try? await Self.remoteETag()
                if let remote, remote == Self.storedETag(), Self.isInstalled() {
                    self.updateAvailable = false
                    self.jobState.finish(
                        .done("specs up to date (\(Self.installedCount()) commands)"), for: job)
                    return
                }
                let count = try await Self.downloadAndInstall()
                self.updateAvailable = false
                self.jobState.finish(.done("specs updated (\(count) commands)"), for: job)
                self.onInstalled?()
                if announce {
                    UpdateNotice.post("Completion specs updated", "\(count) commands are ready.")
                }
            } catch {
                self.jobState.finish(.failed(error.localizedDescription), for: job)
            }
        }
    }

    enum UpdateAction: Equatable { case none, adoptBaseline, flag, autoInstall }

    nonisolated static func updateAction(remote: String?, stored: String?,
                                         autoInstall: Bool) -> UpdateAction {
        guard let remote else { return .none }
        guard let stored else { return .adoptBaseline }
        guard remote != stored else { return .none }
        return autoInstall ? .autoInstall : .flag
    }

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

    /// Skip this and an app update's builtin-spec changes never reach an already-installed pack.
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

    /// Copying the .js files alone isn't enough — skip the index.json registration and they never resolve.
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
