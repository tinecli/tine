import Darwin
import Foundation

enum ShellIntegration {
    static let sourceLine = "source ~/.local/share/tine/tine.zsh"

    enum Status: Equatable {
        case installed
        case commentedOut
        case missing
        case refused(String)

        var isInstalled: Bool { self == .installed }

        var detail: String {
            switch self {
            case .installed:
                return "Installed"
            case .commentedOut:
                return "Found a commented-out tine line — remove the # to re-enable."
            case .missing:
                return "Not installed"
            case .refused(let reason):
                return reason
            }
        }

        var diagnosticDetail: String {
            switch self {
            case .installed: return "installed"
            case .commentedOut: return "commented out"
            case .missing: return "not installed"
            case .refused(let reason): return reason
            }
        }
    }

    static func zshrcPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                          homeDirectory: String = NSHomeDirectory()) -> String {
        let dotDirectory = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory
        return URL(fileURLWithPath: dotDirectory).appendingPathComponent(".zshrc").path
    }

    static func status(at path: String, expectedUID: uid_t = getuid()) -> Status {
        switch resolve(path: path, expectedUID: expectedUID) {
        case .missing:
            return .missing
        case .refused(let reason):
            return .refused(reason)
        case .file(let resolvedPath, let expectedIdentity):
            let descriptor = Darwin.open(resolvedPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                return .refused("Refused to read .zshrc: \(errorMessage()).")
            }
            defer { Darwin.close(descriptor) }
            guard validate(descriptor: descriptor, expectedUID: expectedUID,
                           expectedIdentity: expectedIdentity) else {
                return .refused("Refused to read .zshrc because it changed during validation.")
            }
            switch readAll(from: descriptor) {
            case .success(let data):
                return lineStatus(in: data)
            case .failure(let reason):
                return .refused("Refused to read .zshrc: \(reason).")
            }
        }
    }

    static func addSourceLine(to path: String, expectedUID: uid_t = getuid(),
                              now: Date = Date()) -> Status {
        switch resolve(path: path, expectedUID: expectedUID) {
        case .missing:
            return createZshrc(at: path, expectedUID: expectedUID)
        case .refused(let reason):
            return .refused(reason)
        case .file(let resolvedPath, let expectedIdentity):
            return appendSourceLine(to: resolvedPath, backupSiblingOf: path,
                                    expectedUID: expectedUID,
                                    expectedIdentity: expectedIdentity, now: now)
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private enum Resolution {
        case missing
        case file(String, FileIdentity)
        case refused(String)
    }

    private enum OperationResult<Value> {
        case success(Value)
        case failure(String)
    }

    private static func resolve(path: String, expectedUID: uid_t) -> Resolution {
        var currentPath = URL(fileURLWithPath: path).standardized.path
        var visited = Set<String>()
        var followedSymlink = false

        for _ in 0..<40 {
            guard visited.insert(currentPath).inserted else {
                return .refused("Refused to use .zshrc because its symlink chain contains a loop.")
            }
            var metadata = stat()
            guard lstat(currentPath, &metadata) == 0 else {
                if errno == ENOENT {
                    return followedSymlink
                        ? .refused("Refused to use .zshrc because its symlink target does not exist.")
                        : .missing
                }
                return .refused("Refused to inspect .zshrc: \(errorMessage()).")
            }

            let kind = metadata.st_mode & S_IFMT
            if kind == S_IFLNK {
                guard metadata.st_uid == expectedUID else {
                    return .refused(
                        "Refused to use .zshrc because a symlink in its chain is owned by another user."
                    )
                }
                switch symbolicLinkDestination(at: currentPath) {
                case .failure(let reason):
                    return .refused("Refused to inspect the .zshrc symlink: \(reason).")
                case .success(let destination):
                    let nextPath: String
                    if destination.hasPrefix("/") {
                        nextPath = destination
                    } else {
                        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
                        nextPath = parent.appendingPathComponent(destination).path
                    }
                    currentPath = URL(fileURLWithPath: nextPath).standardized.path
                    followedSymlink = true
                }
                continue
            }
            guard kind == S_IFREG else {
                return .refused("Refused to use .zshrc because it is not a regular file.")
            }
            guard metadata.st_uid == expectedUID else {
                return .refused("Refused to use .zshrc because it is owned by another user.")
            }
            return .file(currentPath, FileIdentity(device: metadata.st_dev,
                                                   inode: metadata.st_ino))
        }
        return .refused("Refused to use .zshrc because its symlink chain is too long.")
    }

    private static func appendSourceLine(to resolvedPath: String, backupSiblingOf path: String,
                                         expectedUID: uid_t, expectedIdentity: FileIdentity,
                                         now: Date) -> Status {
        let descriptor = Darwin.open(
            resolvedPath, O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            return .refused(
                "Refused to update .zshrc because it is not readable and writable: \(errorMessage())."
            )
        }
        defer { Darwin.close(descriptor) }
        // Refuse after opening too, or a path swap could append to an unrecognized file.
        guard validate(descriptor: descriptor, expectedUID: expectedUID,
                       expectedIdentity: expectedIdentity) else {
            return .refused("Refused to update .zshrc because it changed during validation.")
        }
        let contents: Data
        switch readAll(from: descriptor) {
        case .success(let data):
            contents = data
        case .failure(let reason):
            return .refused("Refused to update .zshrc because it could not be read: \(reason).")
        }
        let existingStatus = lineStatus(in: contents)
        guard existingStatus == .missing else { return existingStatus }

        let backupPath = path + ".tine-backup-\(Int(now.timeIntervalSince1970))"
        if let refusal = createBackup(contents, at: backupPath) { return .refused(refusal) }

        let separator = contents.isEmpty || contents.last == 0x0A ? "" : "\n"
        let addition = Data("\(separator)\(sourceLine)\n".utf8)
        guard writeAll(addition, to: descriptor) else {
            return .refused("Could not append the tine source line to .zshrc: \(errorMessage()).")
        }
        return status(at: path, expectedUID: expectedUID)
    }

    private static func createZshrc(at path: String, expectedUID: uid_t) -> Status {
        let descriptor = Darwin.open(
            path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST { return addSourceLine(to: path, expectedUID: expectedUID) }
            return .refused("Could not create .zshrc: \(errorMessage()).")
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == expectedUID,
              metadata.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            return .refused("Refused to write the newly created .zshrc because it failed validation.")
        }
        guard writeAll(Data("\(sourceLine)\n".utf8), to: descriptor) else {
            return .refused("Could not write the tine source line to the new .zshrc: \(errorMessage()).")
        }
        return status(at: path, expectedUID: expectedUID)
    }

    private static func createBackup(_ contents: Data, at path: String) -> String? {
        let descriptor = Darwin.open(
            path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)
        )
        guard descriptor >= 0 else {
            return "Could not create the .zshrc backup at \(path): \(errorMessage())."
        }
        defer { Darwin.close(descriptor) }
        guard writeAll(contents, to: descriptor), fsync(descriptor) == 0 else {
            let reason = errorMessage()
            _ = Darwin.unlink(path)
            return "Could not finish the .zshrc backup at \(path): \(reason)."
        }
        return nil
    }

    private static func lineStatus(in data: Data) -> Status {
        let contents = String(decoding: data, as: UTF8.self)
        let matchingLines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("tine.zsh") }
        guard !matchingLines.isEmpty else { return .missing }
        let onlyCommented = matchingLines.allSatisfy {
            $0.drop(while: { $0 == " " || $0 == "\t" }).first == "#"
        }
        return onlyCommented ? .commentedOut : .installed
    }

    private static func validate(descriptor: Int32, expectedUID: uid_t,
                                 expectedIdentity: FileIdentity) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == expectedUID
            && FileIdentity(device: metadata.st_dev, inode: metadata.st_ino) == expectedIdentity
    }

    private static func symbolicLinkDestination(at path: String) -> OperationResult<String> {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count >= 0 else { return .failure(errorMessage()) }
        return .success(String(decoding: buffer.prefix(Int(count)).map(UInt8.init), as: UTF8.self))
    }

    private static func readAll(from descriptor: Int32) -> OperationResult<Data> {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return .failure(errorMessage()) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return .success(result) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(errorMessage())
            }
            result.append(buffer, count: count)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written),
                                         bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                written += count
            }
            return true
        }
    }

    private static func errorMessage() -> String {
        String(cString: strerror(errno))
    }
}
