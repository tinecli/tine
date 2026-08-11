import Foundation
import Darwin

struct DoctorReport: Equatable {
    enum PanelPlacement: String, Equatable {
        case awaitingInput = "Waiting for terminal input"
        case accessibilityCaret = "Accessibility caret"
        case terminalGrid = "Terminal grid"
        case cornerFallback = "Screen corner fallback"
    }

    static let shellSourceLine = ShellIntegration.sourceLine

    let accessibilityGranted: Bool
    let shellIntegration: ShellIntegration.Status
    let specCount: Int
    let packUpdateAvailable: Bool
    let appVersion: String
    let latestAppVersion: String?
    let stagedAppVersion: String?
    let socketPath: String
    let socketListening: Bool
    let panelPlacement: PanelPlacement

    var shellInstalled: Bool { shellIntegration.isInstalled }

    var socketValue: String {
        "ax=\(accessibilityGranted ? 1 : 0);specs=\(specCount);"
            + "version=\(appVersion);update=\(packUpdateAvailable ? 1 : 0);"
            + "appLatest=\(latestAppVersion ?? "");appStaged=\(stagedAppVersion ?? "")"
    }

    func diagnostics(logPath: String = TineLog.path) -> String {
        let values = [
            "Accessibility: \(accessibilityGranted ? "granted" : "not granted")",
            "Shell integration: \(shellIntegration.diagnosticDetail)",
            "Completion specs: \(specCount)",
            "Spec pack update: \(packUpdateAvailable ? "available" : "none pending")",
            "App version: \(appVersion)",
            "Latest app version: \(latestAppVersion ?? "not reported")",
            "Staged app version: \(stagedAppVersion ?? "none")",
            "Socket path: \(socketPath)",
            "Panel placement: \(panelPlacement.rawValue)",
        ]
        let logTail = TineLog.tail(from: logPath)
        let tail = logTail.isEmpty ? "(empty)" : logTail
        return (values + ["", "Log tail (\(logPath)):", tail]).joined(separator: "\n")
    }
}

enum TineLog {
    static let path = NSHomeDirectory() + "/.local/share/tine/tine.log"

    static func removeLegacyTemporaryLog(at path: String = "/tmp/tine.log") {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid()
        else { return }
        _ = Darwin.unlink(path)
    }

    static func reset(to path: String = TineLog.path) {
        guard let descriptor = descriptor(at: path, flags: O_WRONLY, create: true) else { return }
        defer { Darwin.close(descriptor) }
        _ = ftruncate(descriptor, 0)
    }

    static func write(_ msg: String, to path: String = TineLog.path) {
        let line = "\(Date()) \(msg)\n"
        guard let data = line.data(using: .utf8),
              let descriptor = descriptor(at: path, flags: O_WRONLY | O_APPEND, create: true)
        else { return }
        defer { Darwin.close(descriptor) }
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = Darwin.write(descriptor, baseAddress, bytes.count)
        }
    }

    static func tail(maxBytes: Int = 4096, from path: String = TineLog.path) -> String {
        guard maxBytes > 0,
              let descriptor = descriptor(at: path, flags: O_RDONLY, create: false)
        else { return "" }
        defer { Darwin.close(descriptor) }
        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0 else { return "" }
        let count = min(maxBytes, Int(end))
        guard lseek(descriptor, end - off_t(count), SEEK_SET) >= 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: count)
        let bytesRead = Darwin.read(descriptor, &bytes, count)
        guard bytesRead > 0 else { return "" }
        return String(decoding: bytes.prefix(bytesRead), as: UTF8.self)
    }

    private static func descriptor(at path: String, flags: Int32, create: Bool) -> Int32? {
        if create, !createParentDirectory(for: path) { return nil }

        var metadata = stat()
        let exists = lstat(path, &metadata) == 0
        if exists {
            // Refuse symlinks and files not owned by this user.
            guard isOwnedRegularFile(metadata) else { return nil }
        } else if errno != ENOENT || !create {
            return nil
        }

        let safeFlags = flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let descriptor: Int32
        if exists {
            descriptor = Darwin.open(path, safeFlags)
        } else {
            descriptor = Darwin.open(path, safeFlags | O_CREAT | O_EXCL, mode_t(0o600))
            if descriptor < 0, errno == EEXIST {
                return self.descriptor(at: path, flags: flags, create: false)
            }
        }
        guard descriptor >= 0 else { return nil }

        guard fstat(descriptor, &metadata) == 0,
              isOwnedRegularFile(metadata),
              fchmod(descriptor, mode_t(0o600)) == 0
        else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func isOwnedRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
    }

    private static func createParentDirectory(for path: String) -> Bool {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var metadata = stat()
        if lstat(parent, &metadata) == 0 {
            return isSafeParentDirectory(metadata)
        }
        guard errno == ENOENT else { return false }

        let intermediate = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(
                atPath: intermediate,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            // Another process may have created the final directory first. It is
            // usable only if the same fail-closed validation still succeeds.
        }
        guard lstat(parent, &metadata) == 0 else { return false }
        return isSafeParentDirectory(metadata)
    }

    private static func isSafeParentDirectory(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFDIR && metadata.st_mode & mode_t(0o022) == 0
    }
}

func tlog(_ msg: String) { TineLog.write(msg) }
