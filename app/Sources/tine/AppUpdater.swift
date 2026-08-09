import AppKit
import UserNotifications

/// Keeps the app on the latest release: reads the newest tag from the
/// `releases/latest` redirect, downloads and verifies the dmg in the background,
/// then swaps the bundle through a detached helper once this process has quit.
/// Never rewrites the running bundle in place, and never installs anything that
/// isn't signed by our Developer ID team.
@MainActor
final class AppUpdater: ObservableObject {
    enum Status: Equatable {
        case idle, checking, downloading
        case upToDate(String)
        case available(String)   // newer release exists, nothing downloaded
        case ready(String)       // verified + staged, waiting for the swap
        case blocked(String)     // self-update impossible here; the user must act
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// The newest release seen, once it is newer than ours. Kept apart from
    /// `status` because a blocked or failed update still has a version to report.
    @Published private(set) var newerVersion: String?

    nonisolated static let releasesURL =
        URL(string: "https://github.com/tinecli/tine/releases/latest")!
    /// Our Developer ID team. A download that doesn't satisfy this never reaches
    /// the bundle, whatever the dmg claims to be.
    nonisolated static let teamRequirement =
        "=anchor apple generic and certificate leaf[subject.OU] = \"82K3YC8HVF\""
    nonisolated static let currentVersion =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var staged: (version: String, app: URL)?
    private var timer: Timer?
    private var swapping = false

    /// The verified version waiting to replace this one on quit.
    var readyVersion: String? { staged?.version }

    /// Plain status line for the `tine update` poll (appUpdateStatus socket case).
    var statusLine: String {
        switch status {
        case .idle: return "idle"
        case .checking: return "checking"
        case .downloading: return "downloading"
        case .upToDate(let v): return "uptodate:\(v)"
        case .available(let v): return "available:\(v)"
        case .ready(let v): return "staged:\(v)"
        case .blocked(let m): return "blocked:\(m.socketSafe)"
        case .failed(let m): return "failed:\(m.socketSafe)"
        }
    }

    /// Only a released .app can replace itself — a dev bundle or a bare `swift
    /// run` binary must never be swapped for the shipping app.
    nonisolated static var isSelfUpdatable: Bool {
        guard let id = Bundle.main.bundleIdentifier, !id.hasSuffix(".dev") else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    /// The swap renames the bundle, so its parent is what has to be writable.
    nonisolated static var installDir: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

    /// Check now, then daily. A staged bundle from a previous run is discarded:
    /// only a bundle this process verified itself is ever installed.
    func start() {
        guard Self.isSelfUpdatable else {
            status = .blocked("this build does not self-update")
            return
        }
        Self.clearStaging()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// Ask GitHub for the latest tag and act on it. Fails closed: an unreachable
    /// network leaves the installed app and the status untouched.
    func check(manual: Bool = false) {
        guard Self.isSelfUpdatable else {
            status = .blocked("this build does not self-update")
            return
        }
        if status == .checking || status == .downloading { return }
        if let staged {
            status = .ready(staged.version)
            return
        }
        status = .checking
        Task { await runCheck(manual: manual) }
    }

    private func runCheck(manual: Bool) async {
        guard let latest = await Self.latestVersion() else {
            status = manual ? .failed("could not reach github.com") : .idle
            return
        }
        guard Self.isNewer(latest, than: Self.currentVersion) else {
            status = .upToDate(Self.currentVersion)
            return
        }
        newerVersion = latest
        // The config key governs the automatic channel only — asking for the
        // update explicitly still installs it, like `tine install` does for specs.
        guard TineConfig.load().autoUpdateApp || manual else {
            settle(.available(latest), "Run `tine update` to install it.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: Self.installDir.path) else {
            settle(.blocked("\(Self.installDir.path) is not writable"),
                   "tine can't update itself where it is installed — download it instead.")
            if manual { NSWorkspace.shared.open(Self.releasesURL) }
            return
        }
        status = .downloading
        do {
            let app = try await Self.downloadVerified(version: latest)
            staged = (latest, app)
            settle(.ready(latest), "Downloaded — relaunch tine to finish the update.")
        } catch {
            // Fail closed and stay quiet: the next check retries, and the reason
            // is there for anyone who asks (Settings, `tine update`).
            Self.clearStaging()
            status = .failed(error.localizedDescription)
            if manual { NSWorkspace.shared.open(Self.releasesURL) }
        }
    }

    /// Land on a final status and tell the user once per new version.
    private func settle(_ next: Status, _ notice: String) {
        status = next
        guard let version = newerVersion else { return }
        UpdateNotice.post("tine \(version) is available", notice, once: "app-\(version)")
    }

    /// Swap now and come back. The helper waits for this process to exit, so the
    /// terminate has to follow the spawn.
    @discardableResult
    func applyAndRelaunch() -> String? {
        if let reason = spawnSwap(relaunch: true) {
            status = .blocked(reason)
            return reason
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        return nil
    }

    /// The user quit with an update staged: swap, but don't drag the app back up.
    func applyOnQuit() {
        guard staged != nil else { return }
        _ = spawnSwap(relaunch: false)
    }

    /// Hand the staged bundle to a detached helper. Returns a reason on refusal.
    private func spawnSwap(relaunch: Bool) -> String? {
        guard !swapping else { return nil }
        guard let staged else { return "no update downloaded" }
        guard FileManager.default.isWritableFile(atPath: Self.installDir.path) else {
            return "\(Self.installDir.path) is not writable"
        }
        guard let script = Self.writeHelper() else { return "could not stage the update helper" }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script, "\(getpid())", staged.app.path,
                            Bundle.main.bundleURL.path, relaunch ? "open" : "quiet"]
        do { try helper.run() } catch { return "could not start the update helper" }
        swapping = true
        return nil
    }

    // MARK: - Release check

    /// Latest published version, from the `releases/latest` redirect target — one
    /// HEAD, no GitHub API, no rate limit. nil on any network or format failure.
    nonisolated static func latestVersion() async -> String? {
        var req = URLRequest(url: releasesURL)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req, delegate: RedirectBlocker()),
              let http = resp as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location")
        else { return nil }
        return version(fromLocation: location)
    }

    /// `…/releases/tag/v0.1.29` → `0.1.29`. Rejects anything that isn't a plain
    /// dotted number, so a surprising redirect can't reach the download URL.
    nonisolated static func version(fromLocation location: String) -> String? {
        guard let tag = location.split(separator: "/").last else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : String(tag)
        guard !v.isEmpty, v.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return v
    }

    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote), l = components(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func components(_ v: String) -> [Int] {
        (v.hasPrefix("v") ? String(v.dropFirst()) : v).split(separator: ".").map { Int($0) ?? 0 }
    }

    nonisolated static func dmgURL(version: String) -> URL {
        URL(string: "https://github.com/tinecli/tine/releases/download/v\(version)/Tine-\(version).dmg")!
    }

    // MARK: - Download, verify, stage

    /// Staged beside the installed bundle, so the swap is a rename on the same
    /// volume. Hidden and versionless: `clearStaging()` sweeps every one of them.
    nonisolated private static func stagingRoot() -> URL {
        installDir.appendingPathComponent(".tine-update-\(UUID().uuidString)")
    }

    nonisolated static func clearStaging() {
        let fm = FileManager.default
        let leftovers = (try? fm.contentsOfDirectory(atPath: installDir.path)) ?? []
        for e in leftovers where e.hasPrefix(".tine-update-") {
            try? fm.removeItem(at: installDir.appendingPathComponent(e))
        }
    }

    /// Download the release dmg, verify the app inside it against our team
    /// requirement, and copy it out. Throws — and leaves nothing behind — unless
    /// the result is a bundle we would be willing to run.
    nonisolated static func downloadVerified(version: String) async throws -> URL {
        let fm = FileManager.default
        let root = stagingRoot()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: root) } }

        let (tmp, resp) = try await URLSession.shared.download(from: dmgURL(version: version))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw fail("update download failed (HTTP error)")
        }
        let dmg = root.appendingPathComponent("Tine.dmg")
        try fm.moveItem(at: tmp, to: dmg)

        let mount = root.appendingPathComponent("mnt")
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                       "-mountpoint", mount.path]) else {
            throw fail("could not open the downloaded disk image")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let source = mount.appendingPathComponent("Tine.app")
        guard bundleVersion(of: source) == version else {
            throw fail("the downloaded app is not version \(version)")
        }
        guard isTrusted(source) else { throw fail("the downloaded app failed signature checks") }

        let app = root.appendingPathComponent("Tine.app")
        guard run("/usr/bin/ditto", [source.path, app.path]), isTrusted(app) else {
            throw fail("the downloaded app failed signature checks")
        }
        keep = true
        return app
    }

    /// Signed, unmodified, and signed by *us*. `spctl` is deliberately not used:
    /// it false-negatives on stapled builds (see #22).
    nonisolated static func isTrusted(_ app: URL) -> Bool {
        run("/usr/bin/codesign", ["--verify", "--strict", "-R", teamRequirement, app.path])
    }

    nonisolated static func bundleVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    nonisolated private static func fail(_ msg: String) -> NSError {
        NSError(domain: "tine", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // MARK: - Swap helper

    /// Runs after we exit, so it can move the bundle we're running from. Every
    /// path arrives as an argument — nothing is interpolated into the script.
    nonisolated static let helperScript = """
    #!/bin/sh
    set -u
    [ "$(id -u)" = "0" ] && exit 1
    pid=$1; staged=$2; target=$3; relaunch=$4
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i+1)); done
    kill -0 "$pid" 2>/dev/null && exit 1
    [ -d "$staged" ] && [ -d "$target" ] || exit 1
    backup="$target.tine-old"
    rm -rf "$backup"
    mv "$target" "$backup" || exit 1
    if ! mv "$staged" "$target"; then
      mv "$backup" "$target"
      exit 1
    fi
    rm -rf "$backup"
    rm -rf "$(dirname "$staged")"
    if [ "$relaunch" = "open" ]; then open "$target"; fi
    rm -f "$0"
    exit 0
    """

    nonisolated static func writeHelper() -> String? {
        let path = NSTemporaryDirectory() + "tine-update-\(UUID().uuidString).sh"
        guard (try? helperScript.write(toFile: path, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return path
    }
}

/// Turns URLSession's automatic redirect following off, so a HEAD on
/// `releases/latest` hands back the 302 (and its `location`) instead of the page.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// User-facing update notices. The permission prompt is deliberately deferred to
/// the first notice worth showing — an agent that stays up for days must not ask
/// at launch, mid-typing.
enum UpdateNotice {
    /// Post a notice, at most once per `key` on this machine.
    static func post(_ title: String, _ body: String, once key: String? = nil) {
        guard TineConfig.load().updateNotifications,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil
        else { return }
        if let key {
            let seen = "tine.notified.\(key)"
            guard !UserDefaults.standard.bool(forKey: seen) else { return }
            UserDefaults.standard.set(true, forKey: seen)
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}

extension String {
    /// Safe to put in a socket reply: the shell reads one line of `;`-joined
    /// fields, so an error message must not carry either separator.
    var socketSafe: String {
        components(separatedBy: CharacterSet(charactersIn: "\n\r;\(TINE_US)\(TINE_RS)"))
            .joined(separator: " ")
    }
}
