import Foundation

/// Fixtures live under a fresh scratch directory per call, never under the
/// user's real ~/.local/share/tine, ~/.config/tine, or ~/.zsh_history.
enum Scratch {
    static func dir(_ name: String) -> String {
        let root = "/private/tmp/tine-tests-\(UUID().uuidString)"
        let dir = root + "/\(name)"
        let permissions = [FileAttributeKey.posixPermissions: NSNumber(value: 0o700)]
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: false, attributes: permissions)
        try? FileManager.default.setAttributes(permissions, ofItemAtPath: root)
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: permissions)
        try? FileManager.default.setAttributes(permissions, ofItemAtPath: dir)
        return dir
    }
}

enum TestSubprocess {
    /// Runs one Swift Testing test in a child process. Use this for tests that
    /// temporarily change process-global state which unrelated suites cannot
    /// safely observe while they run in parallel.
    static func runCurrentTest(
        filteredTo filter: String,
        childEnvironmentKey: String
    ) throws -> Bool {
        if ProcessInfo.processInfo.environment[childEnvironmentKey] == "1" {
            return false
        }

        var arguments = Array(CommandLine.arguments.dropFirst())
        while let filterIndex = arguments.firstIndex(of: "--filter") {
            guard arguments.indices.contains(filterIndex + 1) else {
                throw error("The test runner's --filter option has no value.")
            }
            arguments.removeSubrange(filterIndex...(filterIndex + 1))
        }
        guard let bundleOptionIndex = arguments.firstIndex(of: "--test-bundle-path"),
              arguments.indices.contains(bundleOptionIndex + 1) else {
            throw error("The test runner did not provide --test-bundle-path.")
        }
        let bundlePath = arguments[bundleOptionIndex + 1]
        guard let runnerBundleIndex = arguments.lastIndex(of: bundlePath),
              runnerBundleIndex != bundleOptionIndex + 1 else {
            throw error("The test runner did not provide its bundle executable argument.")
        }
        arguments.insert(contentsOf: ["--filter", filter], at: runnerBundleIndex)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[childEnvironmentKey] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: outputData, as: UTF8.self)
            throw error("Child test failed with status \(process.terminationStatus):\n\(detail)")
        }
        return true
    }

    private static func error(_ description: String) -> NSError {
        NSError(
            domain: "tineTests.TestSubprocess",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
