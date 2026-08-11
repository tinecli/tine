import Foundation
import Testing

private struct ControlledFailure: LocalizedError {
    let label: String
    var errorDescription: String? { "finished \(label)" }
}

private actor ControlledHelp {
    private var started = Set<String>()
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func read(_ command: String) async throws -> String {
        started.insert(command)
        startWaiters.removeValue(forKey: command)?.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters[command] = continuation
        }
        throw ControlledFailure(label: command)
    }

    func waitUntilStarted(_ command: String) async {
        guard !started.contains(command) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[command, default: []].append(continuation)
        }
    }

    func release(_ command: String) {
        releaseWaiters.removeValue(forKey: command)?.resume()
    }
}

private actor ControlledCorpus {
    private var started = Set<String>()
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func build(shellPath: String, packDir: String) async -> AskIndex.Stored {
        started.insert(shellPath)
        startWaiters.removeValue(forKey: shellPath)?.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters[shellPath] = continuation
        }
        return AskIndex.Stored(signature: shellPath, builtAt: .distantPast, entries: [])
    }

    func waitUntilStarted(_ shellPath: String) async {
        guard !started.contains(shellPath) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[shellPath, default: []].append(continuation)
        }
    }

    func release(_ shellPath: String) {
        releaseWaiters.removeValue(forKey: shellPath)?.resume()
    }
}

private actor CallProbe {
    private var called = false

    func markCalled() { called = true }
    func wasCalled() -> Bool { called }
}

@MainActor
struct SpecLearnerAdmissionTests {
    private func learner(
        availability: @escaping () -> String? = { nil },
        help: @escaping SpecHelp = { _ in throw ControlledFailure(label: "unexpected help") },
        jobTimeout: TimeInterval = 150
    ) -> SpecLearner {
        let root = Scratch.dir("spec-learner-admission")
        return SpecLearner(
            localSpecsDirs: [root + "/local"],
            packDir: root + "/pack",
            availability: availability,
            help: help,
            jobTimeout: jobTimeout
        )
    }

    @Test func learnRejectsAnUnavailableModelWithoutStartingWork() async {
        let help = CallProbe()
        let learner = learner(
            availability: { "model unavailable for test" },
            help: { _ in
                await help.markCalled()
                throw ControlledFailure(label: "help")
            }
        )

        #expect(learner.learn(command: "tool", force: false) == "started")
        #expect(learner.statusLine == "failed:model unavailable for test")
        #expect(!(await help.wasCalled()))
    }

    @Test func learnRejectsAnInvalidCommandNameWithoutCheckingAvailability() {
        var checkedAvailability = false
        let learner = learner(availability: {
            checkedAvailability = true
            return nil
        })

        #expect(learner.learn(command: "../tool", force: false) == "started")
        #expect(learner.statusLine == "failed:not a command name: ../tool")
        #expect(!checkedAvailability)
    }

    @Test func learnRejectsBusyAdmissionWithTheRunningCommandLabel() async {
        let help = ControlledHelp()
        let learner = learner(help: { try await help.read($0) })

        #expect(learner.learn(command: "alpha", force: false) == "started")
        await help.waitUntilStarted("alpha")
        #expect(learner.learn(command: "beta", force: false) == "busy:alpha")

        await help.release("alpha")
    }

    @Test func supersededLearnCannotOverwriteTheNewJobsStatus() async {
        let help = ControlledHelp()
        let learner = learner(help: { try await help.read($0) }, jobTimeout: 0)

        #expect(learner.learn(command: "alpha", force: false) == "started")
        await help.waitUntilStarted("alpha")
        #expect(learner.learn(command: "beta", force: false) == "started")
        await help.waitUntilStarted("beta")
        #expect(learner.statusLine == "running:reading beta --help")

        await help.release("alpha")
        for _ in 0..<20 { await Task.yield() }
        #expect(learner.statusLine == "running:reading beta --help")

        await help.release("beta")
        for _ in 0..<20 where learner.statusLine != "failed:finished beta" {
            await Task.yield()
        }
        #expect(learner.statusLine == "failed:finished beta")
    }
}

@MainActor
struct AskerAdmissionTests {
    @Test func defaultDataDirectoryKeepsTheLegacyLocation() {
        let expected = ProcessInfo.processInfo.environment["TINE_DATA_DIR"]
            ?? NSHomeDirectory() + "/.local/share/tine"

        #expect(Asker.defaultDataDirectory() == expected)
    }

    @Test func supersededAskCannotOverwriteTheNewJobsStatus() async {
        let root = Scratch.dir("asker-admission")
        let firstPath = root + "/first-bin"
        let secondPath = root + "/second-bin"
        var path = firstPath
        let corpus = ControlledCorpus()
        let asker = Asker(
            packDir: root + "/pack",
            queryExpansion: { _ in throw ControlledFailure(label: "unexpected expansion") },
            dataDir: { root + "/data" },
            corpusBuilder: { await corpus.build(shellPath: $0, packDir: $1) },
            jobTimeout: 0
        )
        asker.shellPath = { path }

        #expect(asker.ask(question: "first question") == "started")
        await corpus.waitUntilStarted(firstPath)
        path = secondPath
        #expect(asker.ask(question: "second question") == "started")
        await corpus.waitUntilStarted(secondPath)
        #expect(asker.statusLine == "running:indexing the tools on your PATH")

        await corpus.release(firstPath)
        for _ in 0..<20 { await Task.yield() }
        #expect(asker.statusLine == "running:indexing the tools on your PATH")

        await corpus.release(secondPath)
        for _ in 0..<20 where asker.statusLine != "failed:found no tools on your PATH" {
            await Task.yield()
        }
        #expect(asker.statusLine == "failed:found no tools on your PATH")
    }
}
