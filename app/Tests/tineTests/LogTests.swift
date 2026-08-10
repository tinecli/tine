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

    @Test func newLogDirectoryIsOwnerOnly() throws {
        let logPath = Scratch.dir("log-permissions") + "/data/tine/tine.log"

        TineLog.write("created securely", to: logPath)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: logPath).deletingLastPathComponent().path
        )
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o700)
    }
}
