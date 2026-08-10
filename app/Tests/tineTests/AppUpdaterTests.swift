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
}
