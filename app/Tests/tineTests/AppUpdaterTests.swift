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
