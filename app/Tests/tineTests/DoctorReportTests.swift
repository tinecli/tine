import Foundation
import Testing

struct DoctorReportTests {
    private let report = DoctorReport(
        accessibilityGranted: true,
        shellIntegration: .missing,
        specCount: 417,
        packUpdateAvailable: true,
        appVersion: "0.1.31",
        latestAppVersion: "0.1.33",
        stagedAppVersion: "0.1.32",
        socketPath: "/tmp/tine-test.sock",
        socketListening: true,
        panelPlacement: .terminalGrid
    )

    @Test func reportStoresEveryValue() {
        #expect(report.accessibilityGranted)
        #expect(!report.shellInstalled)
        #expect(report.specCount == 417)
        #expect(report.packUpdateAvailable)
        #expect(report.appVersion == "0.1.31")
        #expect(report.latestAppVersion == "0.1.33")
        #expect(report.stagedAppVersion == "0.1.32")
        #expect(report.socketPath == "/tmp/tine-test.sock")
        #expect(report.socketListening)
        #expect(report.panelPlacement == .terminalGrid)
    }

    @Test func socketValuePreservesTheDoctorProtocol() {
        #expect(report.socketValue == "ax=1;specs=417;version=0.1.31;update=1;"
                + "appLatest=0.1.33;appStaged=0.1.32")
    }

    @Test func socketValueUsesEmptyUpdateVersionsAndNumericFlags() {
        let quiet = DoctorReport(
            accessibilityGranted: false,
            shellIntegration: .installed,
            specCount: 0,
            packUpdateAvailable: false,
            appVersion: "?",
            latestAppVersion: nil,
            stagedAppVersion: nil,
            socketPath: "",
            socketListening: false,
            panelPlacement: .awaitingInput
        )

        #expect(quiet.socketValue == "ax=0;specs=0;version=?;update=0;appLatest=;appStaged=")
    }

    @Test func diagnosticsReadTailFromInjectedLogLocation() throws {
        let dir = Scratch.dir("diagnostics-log") + "/.local/share/tine"
        let logPath = dir + "/tine.log"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "second-last\nlast\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        let diagnostics = report.diagnostics(logPath: logPath)

        #expect(diagnostics.contains("Accessibility: granted"))
        #expect(diagnostics.contains("Shell integration: not installed"))
        #expect(diagnostics.contains("Completion specs: 417"))
        #expect(diagnostics.contains("Socket path: /tmp/tine-test.sock"))
        #expect(diagnostics.contains("Log tail (\(logPath))"))
        #expect(diagnostics.hasSuffix("second-last\nlast\n"))
        #expect(!diagnostics.contains(DoctorReport.shellSourceLine))
    }
}
