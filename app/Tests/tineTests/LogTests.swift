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
        let scratch = Scratch.dir("log-permissions")
        let root = scratch + "/existing-data-root"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: root
        )
        let logPath = root + "/data/tine/tine.log"

        TineLog.write("created securely", to: logPath)

        let finalAttributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: logPath).deletingLastPathComponent().path
        )
        let finalPermissions = try #require(finalAttributes[.posixPermissions] as? NSNumber)
        #expect(finalPermissions.intValue & 0o777 == 0o700)
    }

    @Test func globalLoggerUsesAnExplicitPath() throws {
        let logPath = Scratch.dir("explicit-tlog") + "/tine.log"

        tlog("routed to scratch", to: logPath)

        #expect(try String(contentsOfFile: logPath, encoding: .utf8).contains("routed to scratch"))
    }

    @Test func frecencyCorruptStoreLogUsesItsInjectedPath() throws {
        let dir = Scratch.dir("frecency-log-path")
        let storePath = dir + "/frecency.json"
        let logPath = dir + "/tine.log"
        try "not json".write(toFile: storePath, atomically: true, encoding: .utf8)

        let frecency = Frecency(
            historyPath: dir + "/missing-history",
            storePath: storePath,
            logPath: logPath
        )
        frecency.load()
        _ = frecency.setHistoryIgnore("ignored-pattern")

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(contents.contains("frecency: unreadable store moved"))
        #expect(contents.contains("history ignore: 15 chars, compiled: true"))
    }

    @Test func javaScriptEngineLogUsesItsInjectedPath() throws {
        let dir = Scratch.dir("js-engine-log-path")
        let logPath = dir + "/tine.log"

        _ = JSEngine(
            specsDir: dir + "/specs",
            localSpecsDirs: [],
            resourcesDir: dir + "/missing-resources",
            logPath: logPath
        )
        let invalidResources = dir + "/invalid-resources"
        try FileManager.default.createDirectory(
            atPath: invalidResources, withIntermediateDirectories: false)
        try "throw new Error('boom')".write(
            toFile: invalidResources + "/tine-engine.js",
            atomically: true,
            encoding: .utf8
        )
        _ = JSEngine(
            specsDir: dir + "/specs",
            localSpecsDirs: [],
            resourcesDir: invalidResources,
            logPath: logPath
        )

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(contents.contains("engine: missing"))
        #expect(contents.contains("JS EXC:"))
        #expect(contents.contains("engine ready=false"))
    }

    @Test func tailStartsAtACompleteUTF8Character() throws {
        let logPath = Scratch.dir("utf8-tail") + "/tine.log"
        let suffix = String(repeating: "x", count: 4093)
        try Data(("🙂" + suffix).utf8).write(to: URL(fileURLWithPath: logPath))

        let tail = TineLog.tail(maxBytes: 4096, from: logPath)

        #expect(tail == suffix)
        #expect(!tail.hasPrefix("�"))
    }

    @Test func placementLogOnlyWritesWhenFormattedMessageChanges() {
        let gate = TineLogChangeGate<String>()
        let placement = "AX[Ghostty] caret=42 rect=(100, 200, 1, 18) "
            + "anchorRight=false -> (100, 200)"

        #expect(gate.changed(to: placement))
        #expect(!gate.changed(to: placement))
        let flippedProbe = placement.replacingOccurrences(
            of: "anchorRight=false", with: "anchorRight=true")
        #expect(gate.changed(to: flippedProbe))
        #expect(gate.changed(to: flippedProbe.replacingOccurrences(
            of: "AX[Ghostty]", with: "AX[Code]")))

        let failure = "AX[Ghostty] no valid bounds for caret CFRange(location: 42, length: 0)"
        #expect(gate.changed(to: failure))
        #expect(!gate.changed(to: failure))
    }

    @Test func scratchDirectoriesAreOwnerOnly() throws {
        let dir = Scratch.dir("permissions")
        let root = URL(fileURLWithPath: dir).deletingLastPathComponent().path

        for path in [root, dir] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o700)
        }
    }
}
