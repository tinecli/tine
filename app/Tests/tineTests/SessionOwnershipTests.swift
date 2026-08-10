import Testing
import AppKit

/// Stubbed world: which app is frontmost, which terminal each shell runs in,
/// and which terminals are still running. One instance per test — swift-testing
/// runs tests in parallel, so state can't be shared the way the old harness's
/// static vars were.
private final class Stubs {
    var frontmost: pid_t = 100
    var terminals: [pid_t: pid_t] = [:]
    var running: Set<pid_t> = []

    lazy var sessions = SessionOwnership(frontmostPID: { [weak self] in self?.frontmost },
                                         terminalPID: { [weak self] in self?.terminals[$0] },
                                         isRunningApp: { [weak self] in self?.running.contains($0) ?? false })

    func feed(_ buffer: String, cursor: Int = 0, cwd: String = "/tmp") -> FeedMessage {
        FeedMessage(cursor: cursor, cwd: cwd, buffer: buffer)
    }
}

/// Ported from the old SessionHarness (app/Tests/SessionHarness.swift), minus
/// the socket/wire layer — these drive `SessionOwnership.admit` directly.
struct SessionOwnershipTests {
    let a: pid_t = 1001 // shell in terminal app 100
    let b: pid_t = 2002 // shell in terminal app 200

    @Test func typingPresentsThePanelOverItsOwnTerminalAndTakesOwnership() {
        let s = Stubs()
        s.terminals = [a: 100]
        s.frontmost = 100
        let verdict = s.sessions.admit(session: a, s.feed("gi", cursor: 2))
        #expect(verdict?.changed == true)
        #expect(verdict?.appPID == 100)
        #expect(s.sessions.owner == a)
    }

    @Test func backgroundSessionEditWhileAThirdAppIsFrontmostIsIgnored() {
        let s = Stubs()
        s.terminals = [a: 100, b: 200]
        s.frontmost = 100
        _ = s.sessions.admit(session: a, s.feed("gi", cursor: 2))

        s.frontmost = 300
        let verdict = s.sessions.admit(session: b, s.feed("ls -l", cursor: 5))
        #expect(verdict == nil)
        #expect(s.sessions.owner == a, "the owner keeps the panel")
    }

    @Test func backgroundSessionRedrawingAnEmptyLineDoesNotDismiss() {
        let s = Stubs()
        s.terminals = [a: 100, b: 200]
        s.frontmost = 100
        _ = s.sessions.admit(session: a, s.feed("gi", cursor: 2))

        s.frontmost = 300
        let verdict = s.sessions.admit(session: b, s.feed(""))
        #expect(verdict == nil)
        #expect(s.sessions.owner == a)
    }

    @Test func repeatingAnUnchangedEmptyLineIsNotAnEditEvenWithItsOwnTerminalFrontmost() {
        let s = Stubs()
        s.terminals = [a: 100, b: 200]
        s.frontmost = 100
        _ = s.sessions.admit(session: a, s.feed("gi", cursor: 2))

        s.frontmost = 300
        _ = s.sessions.admit(session: b, s.feed(""))
        s.frontmost = 200
        let verdict = s.sessions.admit(session: b, s.feed(""))
        #expect(verdict == nil, "a non-owner's unchanged, empty redraw is not admitted")
        #expect(s.sessions.owner == a, "the panel stays with its owner")
    }

    @Test func ownerRedrawingUnchangedKeepsThePanel() {
        let s = Stubs()
        s.terminals = [a: 100]
        s.frontmost = 100
        _ = s.sessions.admit(session: a, s.feed("gi", cursor: 2))

        let verdict = s.sessions.admit(session: a, s.feed("gi", cursor: 2))
        #expect(verdict?.changed == false)
        #expect(verdict?.appPID == 100)
        #expect(s.sessions.owner == a)
    }

    @Test func editingWithItsOwnTerminalFrontmostTransfersOwnership() {
        let s = Stubs()
        s.terminals = [a: 100, b: 200]
        s.frontmost = 100
        _ = s.sessions.admit(session: a, s.feed("gi", cursor: 2))

        s.frontmost = 200
        let verdict = s.sessions.admit(session: b, s.feed("ls -la", cursor: 6))
        #expect(verdict?.changed == true)
        #expect(verdict?.appPID == 200)
        #expect(s.sessions.owner == b)
    }

    @Test func aSessionWithNoTerminalAncestorKeepsTheOldFrontmostAppBehaviour() {
        let s = Stubs()
        let t: pid_t = 3003 // e.g. tmux/ssh: no application ancestor
        s.frontmost = 300
        let verdict = s.sessions.admit(session: t, s.feed("top", cursor: 3))
        #expect(verdict?.changed == true)
        #expect(verdict?.appPID == 300)
        #expect(s.sessions.owner == t)
    }

    @Test func legacySessionZeroIsAlwaysTreatedAsOwner() {
        let s = Stubs()
        #expect(s.sessions.isOwner(0))
        s.terminals = [1: 100]
        s.frontmost = 100
        _ = s.sessions.admit(session: 1, s.feed("hi"))
        #expect(s.sessions.isOwner(0), "session 0 predates session ids and is always the owner")
    }

    @Test func disownReleasesOwnership() {
        let s = Stubs()
        s.terminals = [a: 100]
        s.frontmost = 100
        _ = s.sessions.admit(session: a, s.feed("gi", cursor: 2))
        s.sessions.disown()
        #expect(s.sessions.owner == nil)
        #expect(!s.sessions.isOwner(a))
    }

    @Test func aReusedPidResolvesToTheNewTerminalOnceTheOldOneHasQuit() {
        let s = Stubs()
        let reused: pid_t = 4004
        s.terminals[reused] = 400
        s.running = [400]
        s.frontmost = 400
        let first = s.sessions.admit(session: reused, s.feed("vim", cursor: 3))
        #expect(first?.appPID == 400)

        s.running.remove(400)
        s.terminals[reused] = 500
        s.running.insert(500)
        s.frontmost = 500
        let second = s.sessions.admit(session: reused, s.feed("vimrc", cursor: 5))
        #expect(second?.appPID == 500, "the cached mapping must not outlive the quit terminal")
        #expect(s.sessions.owner == reused)
    }
}
