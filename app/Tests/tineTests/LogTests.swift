import Foundation
import Testing

struct TineLogTests {
    @Test func logLivesInTheAppDataDirectory() {
        #expect(TineLog.path == NSHomeDirectory() + "/.local/share/tine/tine.log")
    }

    @Test func resetAndWriteRefuseASymlink() throws {
        let dir = Scratch.dir("log-symlink")
        let target = dir + "/target"
        let link = dir + "/tine.log"
        try "unchanged".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        TineLog.reset(to: link)
        TineLog.write("must not follow", to: link)

        #expect(try String(contentsOfFile: target, encoding: .utf8) == "unchanged")
        #expect(TineLog.tail(from: link).isEmpty)
    }

    @Test func resetAndWriteRefuseAGroupWritableParent() throws {
        let dir = Scratch.dir("log-group-writable-parent")
        let logPath = dir + "/tine.log"
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o770)],
            ofItemAtPath: dir
        )

        TineLog.reset(to: logPath)
        TineLog.write("must not create", to: logPath)

        #expect(!FileManager.default.fileExists(atPath: logPath))
        #expect(TineLog.tail(from: logPath).isEmpty)
    }

    @Test func resetAndWriteRefuseAHardlink() throws {
        let dir = Scratch.dir("log-hardlink")
        let target = dir + "/target"
        let link = dir + "/tine.log"
        try "unchanged".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(atPath: target, toPath: link)

        TineLog.reset(to: link)
        TineLog.write("must not follow", to: link)

        #expect(try String(contentsOfFile: target, encoding: .utf8) == "unchanged")
        #expect(TineLog.tail(from: link).isEmpty)
    }

    @Test func legacyCleanupOnlyRemovesAnOwnedRegularFile() throws {
        let dir = Scratch.dir("legacy-log-cleanup")
        let legacyLog = dir + "/tine.log"
        try "legacy contents".write(toFile: legacyLog, atomically: true, encoding: .utf8)

        TineLog.removeLegacyTemporaryLog(at: legacyLog)

        #expect(!FileManager.default.fileExists(atPath: legacyLog))

        let target = dir + "/target"
        try "unchanged".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: legacyLog,
            withDestinationPath: target
        )

        TineLog.removeLegacyTemporaryLog(at: legacyLog)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacyLog) == target)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "unchanged")
    }

    @Test func newLogDirectoryIsOwnerOnly() throws {
        let root = Scratch.dir("log-permissions")
        let logPath = root + "/data/tine/tine.log"
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root)
        let rootPermissions = try #require(rootAttributes[.posixPermissions] as? NSNumber)

        TineLog.write("created securely", to: logPath)

        let finalAttributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: logPath).deletingLastPathComponent().path
        )
        let finalPermissions = try #require(finalAttributes[.posixPermissions] as? NSNumber)
        #expect(finalPermissions.intValue & 0o777 == 0o700)

        let intermediateAttributes = try FileManager.default.attributesOfItem(
            atPath: root + "/data"
        )
        let intermediatePermissions = try #require(
            intermediateAttributes[.posixPermissions] as? NSNumber
        )
        #expect(
            intermediatePermissions.intValue & 0o777 == (rootPermissions.intValue & 0o777)
        )
    }
}
