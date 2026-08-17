import AppKit
import UserNotifications

/// Never rewrite the running bundle in place — swap it through the detached helper instead.
@MainActor
final class AppUpdater: ObservableObject {
    enum Status: Equatable {
        case idle, checking, downloading
        case upToDate(String)
        case available(String)
        case ready(String)
        case blocked(String)
        case failed(String)
    }

    @Published private var jobState = JobState<Status>(.idle)
    @Published private(set) var newerVersion: String?

    var status: Status { jobState.status }

    nonisolated static let releasesURL =
        URL(string: "https://github.com/tinecli/tine/releases/latest")!
    /// Never relax this — an unsigned or wrong-team download must never reach the bundle.
    nonisolated static let teamRequirement =
        "=anchor apple generic and certificate leaf[subject.OU] = \"82K3YC8HVF\""
    nonisolated static let currentVersion =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var staged: (version: String, app: URL)?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var swapping = false

    var readyVersion: String? { staged?.version }

    var updateActionable: Bool {
        guard newerVersion != nil else { return false }
        guard case .blocked = status else { return true }
        return false
    }

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

    /// Must stay false for a dev bundle or bare `swift run` binary, or it tries to self-replace those too.
    nonisolated static var isSelfUpdatable: Bool {
        guard let id = Bundle.main.bundleIdentifier, !id.hasSuffix(".dev") else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Check this dir's writability, not the bundle's — the swap renames the bundle, so the parent is what matters.
    nonisolated static var installDir: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start() {
        guard Self.isSelfUpdatable else {
            jobState.reset(to: .blocked("this build does not self-update"))
            return
        }
        Self.clearStaging() // only a bundle this process verified itself is ever installed
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// Must fail closed — a network error must never touch the installed app or status.
    func check(manual: Bool = false) {
        guard Self.isSelfUpdatable else {
            jobState.reset(to: .blocked("this build does not self-update"))
            return
        }
        if let staged {
            jobState.reset(to: .ready(staged.version))
            return
        }
        let previousStatus = status
        guard case .started(let job) = jobState.start("app update", status: .checking)
        else { return }
        Task { await runCheck(manual: manual, previousStatus: previousStatus, job: job) }
    }

    private func runCheck(manual: Bool, previousStatus: Status,
                          job: JobState<Status>.Job) async {
        guard let latest = await Self.latestVersion() else {
            if manual {
                jobState.finish(.failed("could not reach github.com"), for: job)
            } else if newerVersion != nil {
                jobState.finish(previousStatus, for: job)
            } else {
                jobState.finish(.idle, for: job)
            }
            return
        }
        guard Self.isNewer(latest, than: Self.currentVersion) else {
            newerVersion = nil
            jobState.finish(.upToDate(Self.currentVersion), for: job)
            return
        }
        newerVersion = latest
        // Keep `|| manual` — autoUpdateApp must gate only the automatic channel, not `tine update`.
        guard TineConfig.load().autoUpdateApp || manual else {
            settle(.available(latest), "Run `tine update` to install it.", once: "app-\(latest)",
                   job: job)
            return
        }
        guard FileManager.default.isWritableFile(atPath: Self.installDir.path) else {
            settle(.blocked("\(Self.installDir.path) is not writable"),
                   "tine can't update itself where it is installed — download it instead.",
                   once: "app-\(latest)", job: job)
            if manual { NSWorkspace.shared.open(Self.releasesURL) }
            return
        }
        jobState.report(.downloading, for: job)
        do {
            let app = try await Self.downloadVerified(version: latest)
            staged = (latest, app)
            settle(.ready(latest), "Downloaded — relaunch tine to finish the update.",
                   once: "app-ready-\(latest)", job: job)
        } catch {
            Self.clearStaging()
            jobState.finish(.failed(error.localizedDescription), for: job)
            if manual { NSWorkspace.shared.open(Self.releasesURL) }
        }
    }

    private func settle(_ next: Status, _ notice: String, once key: String,
                        job: JobState<Status>.Job) {
        guard jobState.finish(next, for: job) else { return }
        guard let version = newerVersion else { return }
        UpdateNotice.post("tine \(version) is available", notice, once: key)
    }

    /// Order matters: the helper waits for this pid to exit, so spawn must precede terminate.
    @discardableResult
    func applyAndRelaunch() -> String? {
        if let reason = spawnSwap(relaunch: true) {
            if jobState.busy() == nil {
                jobState.reset(to: .blocked(reason))
            }
            return reason
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        return nil
    }

    func applyOnQuit() {
        guard staged != nil else { return }
        _ = spawnSwap(relaunch: false)
    }

    private func spawnSwap(relaunch: Bool) -> String? {
        guard !swapping else { return nil }
        guard let staged else { return "no update downloaded" }
        // Re-read from disk, don't trust `staged`'s age — a stale read can turn this swap into a downgrade.
        let installed = Self.bundleVersion(of: Bundle.main.bundleURL)
        guard Self.mayInstall(staged.version, over: installed) else {
            self.staged = nil
            Self.clearStaging()
            return "\(installed ?? "?") is already installed"
        }
        guard FileManager.default.isWritableFile(atPath: Self.installDir.path) else {
            return "\(Self.installDir.path) is not writable"
        }
        guard let script = Self.writeHelper() else { return "could not stage the update helper" }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script, "\(getpid())", staged.app.path,
                            Bundle.main.bundleURL.path, relaunch ? "open" : "quiet",
                            installed ?? ""]
        do { try helper.run() } catch { return "could not start the update helper" }
        swapping = true
        return nil
    }

    nonisolated static func latestVersion() async -> String? {
        var req = URLRequest(url: releasesURL)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req, delegate: RedirectBlocker()),
              let http = resp as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location")
        else { return nil }
        return version(fromLocation: location)
    }

    /// Rejects anything but a plain dotted number — this string builds the download URL below.
    nonisolated static func version(fromLocation location: String) -> String? {
        guard let tag = location.split(separator: "/").last else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : String(tag)
        guard !v.isEmpty, v.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." })
        else { return nil }
        return v
    }

    nonisolated static func mayInstall(_ staged: String, over installed: String?) -> Bool {
        guard let installed else { return true }
        return isNewer(staged, than: installed)
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

    /// The `.tine-update-` dot-prefix is load-bearing: `clearStaging()` matches on it to sweep leftovers.
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

    /// `keep` must only flip true after `isTrusted` passes — the defer below deletes anything else.
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

    /// `spctl` is deliberately not used: it false-negatives on stapled builds (see #22).
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

    /// Never interpolate a path into this script — pass it as an argument, or it's shell-injectable.
    nonisolated static let helperScript = """
    #!/bin/sh
    set -u
    [ "$(id -u)" = "0" ] && exit 1
    pid=$1; staged=$2; target=$3; relaunch=$4; expected=$5
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i+1)); done
    kill -0 "$pid" 2>/dev/null && exit 1
    [ -d "$staged" ] && [ -d "$target" ] || exit 1
    # Read it again here, not at spawn: brew or another installer may have replaced
    # the app while we waited, and that install wins.
    now=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
      "$target/Contents/Info.plist" 2>/dev/null)
    [ "$now" = "$expected" ] || exit 1
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

/// Don't remove this — URLSession follows the redirect by default and the 302's `Location` is lost.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum UpdateNotice {
    typealias Authorization = (@escaping (Bool) -> Void) -> Void
    typealias Delivery = (@escaping (Bool) -> Void) -> Void

    private static let onceLock = NSLock()
    private nonisolated(unsafe) static var pending = Set<String>()

    static func post(_ title: String, _ body: String, once key: String? = nil) {
        guard TineConfig.load().updateNotifications,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil
        else { return }
        let center = UNUserNotificationCenter.current()
        deliver(
            once: key, defaults: .standard,
            authorize: { completion in
                center.requestAuthorization(options: [.alert]) { granted, _ in completion(granted) }
            },
            schedule: { completion in
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                 content: content, trigger: nil)) { error in
                    completion(error == nil)
                }
            })
    }

    static func deliver(once key: String?, defaults: UserDefaults,
                        authorize: @escaping Authorization, schedule: @escaping Delivery) {
        let seen = key.map { "tine.notified.\($0)" }
        if let seen {
            let reserved = onceLock.withLock {
                guard !defaults.bool(forKey: seen), !pending.contains(seen) else { return false }
                pending.insert(seen)
                return true
            }
            guard reserved else { return }
        }
        authorize { granted in
            guard granted else {
                finish(seen: seen, delivered: false, defaults: defaults)
                return
            }
            schedule { delivered in
                finish(seen: seen, delivered: delivered, defaults: defaults)
            }
        }
    }

    private static func finish(seen: String?, delivered: Bool, defaults: UserDefaults) {
        guard let seen else { return }
        onceLock.withLock {
            if delivered { defaults.set(true, forKey: seen) }
            pending.remove(seen)
        }
    }
}
