import Foundation

struct DoctorReport: Equatable {
    enum PanelPlacement: String, Equatable {
        case awaitingInput = "Waiting for terminal input"
        case accessibilityCaret = "Accessibility caret"
        case terminalGrid = "Terminal grid"
        case cornerFallback = "Screen corner fallback"
    }

    static let shellSourceLine = "source ~/.local/share/tine/tine.zsh"

    let accessibilityGranted: Bool
    let shellInstalled: Bool
    let specCount: Int
    let packUpdateAvailable: Bool
    let appVersion: String
    let latestAppVersion: String?
    let stagedAppVersion: String?
    let socketPath: String
    let panelPlacement: PanelPlacement

    static func build(
        accessibilityGranted: Bool,
        shellInstalled: Bool,
        specCount: Int,
        packUpdateAvailable: Bool,
        appVersion: String,
        latestAppVersion: String?,
        stagedAppVersion: String?,
        socketPath: String,
        panelPlacement: PanelPlacement
    ) -> DoctorReport {
        DoctorReport(
            accessibilityGranted: accessibilityGranted,
            shellInstalled: shellInstalled,
            specCount: specCount,
            packUpdateAvailable: packUpdateAvailable,
            appVersion: appVersion,
            latestAppVersion: latestAppVersion,
            stagedAppVersion: stagedAppVersion,
            socketPath: socketPath,
            panelPlacement: panelPlacement
        )
    }

    var socketValue: String {
        "ax=\(accessibilityGranted ? 1 : 0);specs=\(specCount);"
            + "version=\(appVersion);update=\(packUpdateAvailable ? 1 : 0);"
            + "appLatest=\(latestAppVersion ?? "");appStaged=\(stagedAppVersion ?? "")"
    }

    func diagnostics(logTail: String) -> String {
        let values = [
            "Accessibility: \(accessibilityGranted ? "granted" : "not granted")",
            "Shell integration: \(shellInstalled ? "installed" : "not installed")",
            "Completion specs: \(specCount)",
            "Spec pack update: \(packUpdateAvailable ? "available" : "none pending")",
            "App version: \(appVersion)",
            "Latest app version: \(latestAppVersion ?? "not reported")",
            "Staged app version: \(stagedAppVersion ?? "none")",
            "Socket path: \(socketPath)",
            "Panel placement: \(panelPlacement.rawValue)",
        ]
        let tail = logTail.isEmpty ? "(empty)" : logTail
        return (values + ["", "Log tail (\(TineLog.path)):", tail]).joined(separator: "\n")
    }
}

enum TineLog {
    static let path = "/tmp/tine.log"

    static func reset() {
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func write(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func tail(maxBytes: Int = 4096) -> String {
        guard maxBytes > 0, let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        let count = min(UInt64(maxBytes), end)
        do {
            try handle.seek(toOffset: end - count)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch {
            return ""
        }
    }
}

func tlog(_ msg: String) { TineLog.write(msg) }
