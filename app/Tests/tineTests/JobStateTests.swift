import Foundation
import Testing

struct JobStateTests {
    enum Status: Equatable {
        case idle
        case running(String)
        case done(String)
        case failed(String)
    }

    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aJobTransitionsThroughRunningStagesAndCompletion() {
        var state = JobState<Status>(.idle, timeout: 10)
        guard case .started(let job) = state.start("first", status: .running("starting"),
                                                  at: now) else {
            Issue.record("the idle state should admit a job")
            return
        }

        #expect(state.status == .running("starting"))
        let reported = state.report(.running("working"), for: job)
        #expect(reported)
        #expect(state.status == .running("working"))
        let finished = state.finish(.done("result"), for: job)
        #expect(finished)
        #expect(state.status == .done("result"))
        #expect(state.busy(at: now) == nil)
    }

    @Test func aLiveJobRejectsAnotherStartWithoutChangingStatus() {
        var state = JobState<Status>(.idle, timeout: 10)
        _ = state.start("first", status: .running("first"), at: now)

        guard case .busy(let label) = state.start("second", status: .running("second"),
                                                  at: now.addingTimeInterval(9)) else {
            Issue.record("the live job should hold the state")
            return
        }
        #expect(label == "first")
        #expect(state.status == .running("first"))
    }

    @Test func theDeadlineExpiresAtTheConfiguredBoundary() {
        var state = JobState<Status>(.idle, timeout: 10)
        _ = state.start("first", status: .running("first"), at: now)

        #expect(state.busy(at: now.addingTimeInterval(9.999)) == "first")
        #expect(state.busy(at: now.addingTimeInterval(10)) == nil)
    }

    @Test func omittingADeadlineKeepsTheJobBusy() {
        var state = JobState<Status>(.idle)
        _ = state.start("first", status: .running("first"), at: now)

        #expect(state.busy(at: .distantFuture) == "first")
    }

    @Test func aReplacementJobCannotBeOverwrittenByItsPredecessor() {
        var state = JobState<Status>(.idle, timeout: 10)
        guard case .started(let first) = state.start("first", status: .running("first"),
                                                     at: now),
              case .started(let second) = state.start("second", status: .running("second"),
                                                      at: now.addingTimeInterval(10)) else {
            Issue.record("an expired job should be superseded")
            return
        }

        let staleReport = state.report(.running("stale"), for: first)
        let staleFinish = state.finish(.failed("stale"), for: first)
        #expect(!staleReport)
        #expect(!staleFinish)
        #expect(state.status == .running("second"))
        let freshFinish = state.finish(.done("fresh"), for: second)
        #expect(freshFinish)
        #expect(state.status == .done("fresh"))
    }

    @Test func resetInvalidatesAnExpiredJobWithoutStartingAnother() {
        var state = JobState<Status>(.idle, timeout: 10)
        guard case .started(let first) = state.start("first", status: .running("first"),
                                                     at: now) else {
            Issue.record("the idle state should admit a job")
            return
        }

        #expect(state.busy(at: now.addingTimeInterval(10)) == nil)
        state.reset(to: .failed("rejected"))
        let staleFinish = state.finish(.done("stale"), for: first)
        #expect(!staleFinish)
        #expect(state.status == .failed("rejected"))
    }
}
