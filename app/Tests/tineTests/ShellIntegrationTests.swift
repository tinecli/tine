import Darwin
import Foundation
import Testing

struct ShellIntegrationTests {
    @Test func appendsWithBackupAndTrailingNewlineHygiene() throws {
        let dir = Scratch.dir("zshrc-append")
        let path = dir + "/.zshrc"
        try "export EDITOR=vim".write(toFile: path, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let status = ShellIntegration.addSourceLine(to: path, now: now)

        #expect(status == .installed)
        #expect(try String(contentsOfFile: path, encoding: .utf8)
                == "export EDITOR=vim\n\(ShellIntegration.sourceLine)\n")
        #expect(try String(contentsOfFile: path + ".tine-backup-1700000000",
                           encoding: .utf8) == "export EDITOR=vim")
    }

    @Test func anExistingLineIsIdempotent() throws {
        let dir = Scratch.dir("zshrc-idempotent")
        let path = dir + "/.zshrc"
        let original = "\(ShellIntegration.sourceLine)\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let status = ShellIntegration.addSourceLine(to: path)

        #expect(status == .installed)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == [".zshrc"])
    }

    @Test func aCommentedOutLineIsReportedAndNeverDuplicated() throws {
        let dir = Scratch.dir("zshrc-commented")
        let path = dir + "/.zshrc"
        let original = "  # \(ShellIntegration.sourceLine)\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let status = ShellIntegration.addSourceLine(to: path)

        #expect(status == .commentedOut)
        #expect(status.detail.contains("remove the #"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == [".zshrc"])
    }

    @Test func followsAnOwnedSymlinkAndBacksUpBesideIt() throws {
        let dir = Scratch.dir("zshrc-symlink")
        let target = dir + "/managed-zshrc"
        let link = dir + "/.zshrc"
        try "export LANG=en_US.UTF-8\n".write(
            toFile: target, atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: "managed-zshrc")
        let now = Date(timeIntervalSince1970: 1_700_000_001)

        let status = ShellIntegration.addSourceLine(to: link, now: now)

        #expect(status == .installed)
        #expect(try String(contentsOfFile: target, encoding: .utf8)
                == "export LANG=en_US.UTF-8\n\(ShellIntegration.sourceLine)\n")
        #expect(try String(contentsOfFile: link + ".tine-backup-1700000001",
                           encoding: .utf8) == "export LANG=en_US.UTF-8\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link)
                == "managed-zshrc")
    }

    @Test func refusesAFileOwnedByAnotherUID() throws {
        let dir = Scratch.dir("zshrc-foreign-owner")
        let path = dir + "/.zshrc"
        try "unchanged\n".write(toFile: path, atomically: true, encoding: .utf8)

        let status = ShellIntegration.addSourceLine(to: path, expectedUID: getuid() + 1)

        guard case .refused(let reason) = status else {
            Issue.record("Expected a refusal, got \(status)")
            return
        }
        #expect(reason.contains("owned by another user"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "unchanged\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == [".zshrc"])
    }

    @Test func createsAMissingFileOwnerOnlyWithoutBackup() throws {
        let dir = Scratch.dir("zshrc-missing")
        let path = dir + "/.zshrc"

        let status = ShellIntegration.addSourceLine(to: path)

        #expect(status == .installed)
        #expect(try String(contentsOfFile: path, encoding: .utf8)
                == "\(ShellIntegration.sourceLine)\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == [".zshrc"])
    }

    @Test func refusesAnUnreadableFile() throws {
        let dir = Scratch.dir("zshrc-unreadable")
        let path = dir + "/.zshrc"
        try "unchanged\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o200)], ofItemAtPath: path
        )

        let status = ShellIntegration.addSourceLine(to: path)

        guard case .refused(let reason) = status else {
            Issue.record("Expected a refusal, got \(status)")
            return
        }
        #expect(reason.contains("not readable and writable"))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path
        )
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "unchanged\n")
    }

    @Test func zDotDirectoryUsesShellDefaultingSemantics() {
        #expect(ShellIntegration.zshrcPath(environment: ["ZDOTDIR": "/private/tmp/zdot"],
                                           homeDirectory: "/private/tmp/home")
                == "/private/tmp/zdot/.zshrc")
        #expect(ShellIntegration.zshrcPath(environment: ["ZDOTDIR": ""],
                                           homeDirectory: "/private/tmp/home")
                == "/private/tmp/home/.zshrc")
        #expect(ShellIntegration.zshrcPath(environment: [:],
                                           homeDirectory: "/private/tmp/home")
                == "/private/tmp/home/.zshrc")
    }
}
