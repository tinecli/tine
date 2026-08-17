import Testing
import AppKit

/// Only the pure, static parts of AppUpdater: version parsing and comparison.
/// Never call `check()`, `start()`, or `downloadVerified` here — they hit the
/// network and ~/.local/share/tine via the swap helper.
struct AppUpdaterTests {
    @Test func versionFromLocationReadsTheTagAfterTheLastSlash() {
        #expect(AppUpdater.version(fromLocation: "https://github.com/tinecli/tine/releases/tag/v0.1.29")
                == "0.1.29")
    }

    @Test func versionFromLocationAcceptsATagWithoutTheVPrefix() {
        #expect(AppUpdater.version(fromLocation: "https://github.com/tinecli/tine/releases/tag/1.2.3")
                == "1.2.3")
    }

    @Test func versionFromLocationRejectsANonDottedNumberTag() {
        #expect(AppUpdater.version(fromLocation: "https://github.com/tinecli/tine/releases/tag/latest")
                == nil)
    }

    @Test func versionFromLocationRejectsAnEmptyTag() {
        #expect(AppUpdater.version(fromLocation: "https://github.com/tinecli/tine/releases/tag/v") == nil)
    }

    @Test func versionFromLocationRejectsNonAsciiDigits() {
        #expect(AppUpdater.version(fromLocation: "https://github.com/x/y/releases/tag/v1.٢.3") == nil)
    }

    @Test func isNewerComparesDotSeparatedComponentsNumerically() {
        #expect(AppUpdater.isNewer("0.2.0", than: "0.1.9"))
        #expect(!AppUpdater.isNewer("0.1.9", than: "0.2.0"))
        #expect(!AppUpdater.isNewer("0.1.9", than: "0.1.9"))
        #expect(AppUpdater.isNewer("0.1.10", than: "0.1.9"), "10 beats 9 numerically, not lexically")
    }

    @Test func isNewerTreatsAMissingTrailingComponentAsZero() {
        #expect(!AppUpdater.isNewer("1.2", than: "1.2.0"))
        #expect(AppUpdater.isNewer("1.2.1", than: "1.2"))
    }

    @Test func mayInstallAllowsReplacingAnUnreadableInstall() {
        // An unreadable target is a broken install, not a newer one — replacing
        // it is a repair.
        #expect(AppUpdater.mayInstall("0.1.0", over: nil))
    }

    @Test func mayInstallRequiresTheStagedVersionToBeStrictlyNewer() {
        #expect(AppUpdater.mayInstall("0.2.0", over: "0.1.0"))
        #expect(!AppUpdater.mayInstall("0.1.0", over: "0.2.0"))
        #expect(!AppUpdater.mayInstall("0.1.0", over: "0.1.0"), "never a downgrade or a no-op swap")
    }

    @Test func theSwapHelperInstallsTheStagedAppWhenTheTargetIsUntouched() throws {
        let bundles = try SwapHelperFixture(target: "0.1.36", staged: "0.1.37")

        #expect(try bundles.run(expecting: "0.1.36") == 0)
        #expect(AppUpdater.bundleVersion(of: bundles.target) == "0.1.37")
        #expect(!FileManager.default.fileExists(atPath: bundles.staged.path))
    }

    @Test func theSwapHelperKeepsAnInstallThatLandedWhileItWaited() throws {
        let bundles = try SwapHelperFixture(target: "0.1.36", staged: "0.1.37")
        try bundles.writeTarget(version: "0.1.38")

        #expect(try bundles.run(expecting: "0.1.36") != 0)
        #expect(AppUpdater.bundleVersion(of: bundles.target) == "0.1.38")
    }

    @Test func theSwapHelperStillRepairsATargetWithNoReadableVersion() throws {
        let bundles = try SwapHelperFixture(target: "0.1.36", staged: "0.1.37")
        try FileManager.default.removeItem(
            at: bundles.target.appendingPathComponent("Contents/Info.plist"))

        #expect(try bundles.run(expecting: "") == 0)
        #expect(AppUpdater.bundleVersion(of: bundles.target) == "0.1.37")
    }

    @Test func deniedAuthorizationDoesNotConsumeTheVersionNotice() throws {
        let suite = "tine-update-notice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "app-9.9.9"
        let marker = "tine.notified.\(key)"
        var authorization: ((Bool) -> Void)?
        var delivery: ((Bool) -> Void)?

        UpdateNotice.deliver(
            once: key, defaults: defaults,
            authorize: { authorization = $0 }, schedule: { delivery = $0 })
        #expect(!defaults.bool(forKey: marker))
        authorization?(false)
        #expect(!defaults.bool(forKey: marker))

        authorization = nil
        UpdateNotice.deliver(
            once: key, defaults: defaults,
            authorize: { authorization = $0 }, schedule: { delivery = $0 })
        authorization?(true)
        #expect(delivery != nil)
        #expect(!defaults.bool(forKey: marker))
        delivery?(true)
        #expect(defaults.bool(forKey: marker))

        authorization = nil
        UpdateNotice.deliver(
            once: key, defaults: defaults,
            authorize: { authorization = $0 }, schedule: { _ in })
        #expect(authorization == nil)
    }

    @Test func failedDeliveryLeavesTheVersionNoticeRetryable() throws {
        let suite = "tine-update-notice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "app-8.8.8"
        let marker = "tine.notified.\(key)"

        UpdateNotice.deliver(
            once: key, defaults: defaults,
            authorize: { $0(true) }, schedule: { $0(false) })
        #expect(!defaults.bool(forKey: marker))

        UpdateNotice.deliver(
            once: key, defaults: defaults,
            authorize: { $0(true) }, schedule: { $0(true) })
        #expect(defaults.bool(forKey: marker))
    }
}

/// The staged app needs its own parent directory — the helper deletes that on success.
private struct SwapHelperFixture {
    let root: String
    let target: URL
    let staged: URL

    init(target targetVersion: String, staged stagedVersion: String) throws {
        root = Scratch.dir("swap")
        target = URL(fileURLWithPath: root + "/Applications/Tine.app")
        staged = URL(fileURLWithPath: root + "/staging/Tine.app")
        try writeTarget(version: targetVersion)
        try Self.write(version: stagedVersion, to: staged)
    }

    func writeTarget(version: String) throws {
        try Self.write(version: version, to: target)
    }

    /// Runs the real helper against an already-exited pid, so its wait loop falls straight through.
    func run(expecting expected: String) throws -> Int32 {
        let script = root + "/swap.sh"
        try AppUpdater.helperScript.write(toFile: script, atomically: true, encoding: .utf8)
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script, "\(exited.processIdentifier)", staged.path, target.path,
                            "quiet", expected]
        try helper.run()
        helper.waitUntilExit()
        return helper.terminationStatus
    }

    private static func write(version: String, to app: URL) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
