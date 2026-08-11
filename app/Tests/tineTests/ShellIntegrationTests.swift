import Darwin
import Foundation
import Testing

@Suite(.serialized)
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

    @Test func martineScriptNameDoesNotCountAsInstalled() throws {
        let dir = Scratch.dir("zshrc-martine")
        let path = dir + "/.zshrc"
        try "source ~/.local/share/martine.zsh\n".write(
            toFile: path, atomically: true, encoding: .utf8
        )

        #expect(ShellIntegration.status(at: path) == .missing)
    }

    @Test func aliasMentioningTineScriptNameDoesNotCountAsInstalled() throws {
        let dir = Scratch.dir("zshrc-alias-mention")
        let path = dir + "/.zshrc"
        try "alias t='echo tine.zsh'\n".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(ShellIntegration.status(at: path) == .missing)
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

    @Test func dotDotAfterSymlinkUsesKernelPathResolution() throws {
        let dir = Scratch.dir("zshrc-symlink-dotdot")
        let targetDirectory = dir + "/actual"
        let nestedDirectory = targetDirectory + "/nested"
        try FileManager.default.createDirectory(
            atPath: nestedDirectory, withIntermediateDirectories: true
        )
        let link = dir + "/jump"
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: "actual/nested"
        )
        let kernelResolvedPath = targetDirectory + "/.zshrc"
        let lexicallyStandardizedPath = dir + "/.zshrc"
        try "kernel target\n".write(
            toFile: kernelResolvedPath, atomically: true, encoding: .utf8
        )
        try "lexical target\n".write(
            toFile: lexicallyStandardizedPath, atomically: true, encoding: .utf8
        )
        let path = link + "/../.zshrc"

        let status = ShellIntegration.addSourceLine(
            to: path, now: Date(timeIntervalSince1970: 1_700_000_002)
        )

        #expect(status == .installed)
        #expect(try String(contentsOfFile: kernelResolvedPath, encoding: .utf8)
                == "kernel target\n\(ShellIntegration.sourceLine)\n")
        #expect(try String(contentsOfFile: lexicallyStandardizedPath, encoding: .utf8)
                == "lexical target\n")
    }

    @Test func failedAppendRestoresOriginalBytes() throws {
        let dir = Scratch.dir("zshrc-partial-append")
        let path = dir + "/.zshrc"
        let original = Data("export EDITOR=vim\n".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        let now = Date(timeIntervalSince1970: 1_700_000_003)
        let backupPath = path + ".tine-backup-1700000003"

        var originalLimit = rlimit()
        #expect(getrlimit(RLIMIT_FSIZE, &originalLimit) == 0)
        var limited = originalLimit
        limited.rlim_cur = rlim_t(original.count + 10)
        let previousSignalHandler = signal(SIGXFSZ, SIG_IGN)
        defer {
            _ = setrlimit(RLIMIT_FSIZE, &originalLimit)
            _ = signal(SIGXFSZ, previousSignalHandler)
        }
        #expect(setrlimit(RLIMIT_FSIZE, &limited) == 0)

        let status = ShellIntegration.addSourceLine(to: path, now: now)

        guard case .refused(let reason) = status else {
            Issue.record("Expected a refusal, got \(status)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("restore"))
        #expect(reason.contains(backupPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == original)
    }

    @Test func backupIsOwnerReadableUnderHostileUmask() throws {
        let dir = Scratch.dir("zshrc-backup-mode")
        let path = dir + "/.zshrc"
        try "export EDITOR=vim\n".write(toFile: path, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_004)
        let backupPath = path + ".tine-backup-1700000004"
        let previousMask = umask(mode_t(0o777))
        defer { _ = umask(previousMask) }

        let status = ShellIntegration.addSourceLine(to: path, now: now)

        #expect(status == .installed)
        let attributes = try FileManager.default.attributesOfItem(atPath: backupPath)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test func refusesToReplaceAPreexistingBackup() throws {
        let dir = Scratch.dir("zshrc-existing-backup")
        let path = dir + "/.zshrc"
        let original = "export EDITOR=vim\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_005)
        let backupPath = path + ".tine-backup-1700000005"
        try "preexisting\n".write(toFile: backupPath, atomically: true, encoding: .utf8)

        let status = ShellIntegration.addSourceLine(to: path, now: now)

        guard case .refused = status else {
            Issue.record("Expected a refusal, got \(status)")
            return
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        #expect(try String(contentsOfFile: backupPath, encoding: .utf8) == "preexisting\n")
    }

    @Test func refusesABackupSymlinkWithoutChangingItsVictim() throws {
        let dir = Scratch.dir("zshrc-backup-symlink")
        let path = dir + "/.zshrc"
        let original = "export EDITOR=vim\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        let victim = dir + "/victim"
        try "do not overwrite\n".write(toFile: victim, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_006)
        let backupPath = path + ".tine-backup-1700000006"
        try FileManager.default.createSymbolicLink(
            atPath: backupPath, withDestinationPath: "victim"
        )

        let status = ShellIntegration.addSourceLine(to: path, now: now)

        guard case .refused = status else {
            Issue.record("Expected a refusal, got \(status)")
            return
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        #expect(try String(contentsOfFile: victim, encoding: .utf8) == "do not overwrite\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: backupPath) == "victim")
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
