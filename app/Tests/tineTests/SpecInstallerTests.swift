import Testing
import Foundation

/// Only the pure static parts of SpecInstaller: what a check should do about a
/// remote/stored ETag pair, and pack-shape validation over a scratch directory.
/// Never call `install()`, `startChecking()`, or `checkForUpdate()` here — they
/// hit the network and ~/.local/share/tine.
struct SpecInstallerTests {
    @Test func noRemoteEtagActsOnNothing() {
        #expect(SpecInstaller.updateAction(remote: nil, stored: "abc", autoInstall: true) == .none)
        #expect(SpecInstaller.updateAction(remote: nil, stored: nil, autoInstall: true) == .none)
    }

    @Test func noStoredMarkerAdoptsTheCurrentPackAsTheBaseline() {
        #expect(SpecInstaller.updateAction(remote: "abc", stored: nil, autoInstall: true) == .adoptBaseline)
    }

    @Test func matchingEtagsDoNothing() {
        #expect(SpecInstaller.updateAction(remote: "abc", stored: "abc", autoInstall: true) == .none)
        #expect(SpecInstaller.updateAction(remote: "abc", stored: "abc", autoInstall: false) == .none)
    }

    @Test func aChangedEtagAutoInstallsOnlyWhenConfigured() {
        #expect(SpecInstaller.updateAction(remote: "new", stored: "old", autoInstall: true) == .autoInstall)
        #expect(SpecInstaller.updateAction(remote: "new", stored: "old", autoInstall: false) == .flag)
    }

    @Test func validateRejectsAPackWithNoIndex() {
        let dir = Scratch.dir("pack-no-index")
        #expect(throws: (any Error).self) { try SpecInstaller.validate(pack: dir) }
    }

    @Test func validateRejectsAPackThatLooksTruncated() throws {
        let dir = Scratch.dir("pack-truncated")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: dir + "/index.json"))
        try Data().write(to: URL(fileURLWithPath: dir + "/one.js"))
        #expect(throws: (any Error).self) { try SpecInstaller.validate(pack: dir) }
    }

    @Test func validateRejectsAPackAtTheMinimumCommandCount() throws {
        let dir = Scratch.dir("pack-minimum")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: dir + "/index.json"))
        for i in 0..<SpecInstaller.minimumPackCommands {
            try Data().write(to: URL(fileURLWithPath: "\(dir)/tool\(i).js"))
        }
        #expect(throws: (any Error).self) { try SpecInstaller.validate(pack: dir) }
    }

    @Test func validateAcceptsAPackAboveTheMinimumCommandCount() throws {
        let dir = Scratch.dir("pack-full")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: dir + "/index.json"))
        for i in 0..<(SpecInstaller.minimumPackCommands + 1) {
            try Data().write(to: URL(fileURLWithPath: "\(dir)/tool\(i).js"))
        }
        try SpecInstaller.validate(pack: dir)
    }
}
