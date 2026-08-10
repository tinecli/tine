import Testing

struct DoctorReportTests {
    private let report = DoctorReport.build(
        accessibilityGranted: true,
        shellInstalled: false,
        specCount: 417,
        packUpdateAvailable: true,
        appVersion: "0.1.31",
        latestAppVersion: "0.1.33",
        stagedAppVersion: "0.1.32",
        socketPath: "/tmp/tine-test.sock",
        panelPlacement: .terminalGrid
    )

    @Test func builderAssemblesEveryReportValue() {
        #expect(report.accessibilityGranted)
        #expect(!report.shellInstalled)
        #expect(report.specCount == 417)
        #expect(report.packUpdateAvailable)
        #expect(report.appVersion == "0.1.31")
        #expect(report.latestAppVersion == "0.1.33")
        #expect(report.stagedAppVersion == "0.1.32")
        #expect(report.socketPath == "/tmp/tine-test.sock")
        #expect(report.panelPlacement == .terminalGrid)
    }

    @Test func socketValuePreservesTheDoctorProtocol() {
        #expect(report.socketValue == "ax=1;specs=417;version=0.1.31;update=1;"
                + "appLatest=0.1.33;appStaged=0.1.32")
    }

    @Test func socketValueUsesEmptyUpdateVersionsAndNumericFlags() {
        let quiet = DoctorReport.build(
            accessibilityGranted: false,
            shellInstalled: true,
            specCount: 0,
            packUpdateAvailable: false,
            appVersion: "?",
            latestAppVersion: nil,
            stagedAppVersion: nil,
            socketPath: "",
            panelPlacement: .awaitingInput
        )

        #expect(quiet.socketValue == "ax=0;specs=0;version=?;update=0;appLatest=;appStaged=")
    }

    @Test func diagnosticsContainReportValuesAndOnlyTheSuppliedLogTail() {
        let diagnostics = report.diagnostics(logTail: "second-last\nlast\n")

        #expect(diagnostics.contains("Accessibility: granted"))
        #expect(diagnostics.contains("Shell integration: not installed"))
        #expect(diagnostics.contains("Completion specs: 417"))
        #expect(diagnostics.contains("Socket path: /tmp/tine-test.sock"))
        #expect(diagnostics.hasSuffix("second-last\nlast\n"))
        #expect(!diagnostics.contains(DoctorReport.shellSourceLine))
    }
}
