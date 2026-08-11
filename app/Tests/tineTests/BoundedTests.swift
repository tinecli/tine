import Dispatch
import Foundation
import Testing

private actor LateCompletionProbe {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markCompleted() {
        completed = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitForCompletion() async {
        guard !completed else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

struct BoundedTests {
    @Test func deadlineAbandonsUncancellableExpansion() async {
        let deadline: TimeInterval = 0.05
        let mockSleep: TimeInterval = 5.0
        let probe = LateCompletionProbe()
        let clock = ContinuousClock()
        let started = clock.now

        let result = await Asker.boundedExpansion(
            question: "shrink a video", timeout: deadline
        ) { _ in
            let expansion: ExpandedSearchTerms = await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + mockSleep) {
                    continuation.resume(returning: ExpandedSearchTerms(
                        terms: ["compress", "encode", "movie"]
                    ))
                }
            }
            await probe.markCompleted()
            return expansion
        }

        let duration = started.duration(to: clock.now)
        let elapsed = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        print(String(format: "bounded wedge elapsed: %.3fs (deadline: %.3fs, mock: %.3fs)",
                     elapsed, deadline, mockSleep))
        #expect(result == nil)
        #expect(elapsed >= deadline * 0.5)
        #expect(elapsed < 2.0)

        await probe.waitForCompletion()
        #expect(result == nil)
    }
}
