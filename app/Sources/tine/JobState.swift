import Foundation

struct JobState<Status> {
    struct Job: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    enum Admission {
        case started(Job)
        case busy(String)
    }

    private struct ActiveJob {
        let job: Job
        let label: String
        let deadline: Date?
    }

    private(set) var status: Status
    private let timeout: TimeInterval?
    private var active: ActiveJob?
    private var nextID: UInt64 = 0

    init(_ status: Status, timeout: TimeInterval? = nil) {
        self.status = status
        self.timeout = timeout
    }

    func busy(at now: Date = Date()) -> String? {
        guard let active else { return nil }
        guard let deadline = active.deadline else { return active.label }
        return now < deadline ? active.label : nil
    }

    mutating func start(_ label: String, status: Status,
                        at now: Date = Date()) -> Admission {
        if let label = busy(at: now) { return .busy(label) }
        nextID &+= 1
        let job = Job(id: nextID)
        active = ActiveJob(job: job, label: label,
                           deadline: timeout.map { now.addingTimeInterval($0) })
        self.status = status
        return .started(job)
    }

    @discardableResult
    mutating func report(_ status: Status, for job: Job) -> Bool {
        guard active?.job == job else { return false }
        self.status = status
        return true
    }

    @discardableResult
    mutating func finish(_ status: Status, for job: Job) -> Bool {
        guard active?.job == job else { return false }
        active = nil
        self.status = status
        return true
    }

    mutating func reset(to status: Status) {
        active = nil
        self.status = status
    }
}
