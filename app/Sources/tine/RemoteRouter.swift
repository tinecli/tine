import Foundation

protocol RemotePanel: AnyObject {
    var panelIsVisible: Bool { get }
    func record(feed: Request)
    func present(over app: pid_t, buffer: String)
    func dismissPanel()
    func scheduleIdleHide()
    func relayoutPanel()
}

/// Wire format: `token US <local wire line>`.
final class RemoteRouter {
    static let verbs: Set<String> = ["update", "up", "down", "accept", "prefix", "dismiss", "version"]

    private let state: AppState
    private let sessions: SessionOwnership
    private let tokens: RemoteSessions
    private weak var panel: RemotePanel?
    private let version: String

    init(state: AppState, sessions: SessionOwnership, tokens: RemoteSessions,
         panel: RemotePanel, version: String) {
        self.state = state
        self.sessions = sessions
        self.tokens = tokens
        self.panel = panel
        self.version = version
    }

    func respond(to line: String) -> String? {
        guard let cut = line.range(of: TINE_US),
              let session = tokens.session(for: String(line[..<cut.lowerBound])) else { return nil }
        guard var req = Request(line: String(line[cut.upperBound...])),
              Self.verbs.contains(req.type), let panel else { return "0" }
        req.session = session
        let ownsRemotePanel = panel.panelIsVisible && state.showsRemote && sessions.isOwner(session)
        switch req.type {
        case "update":
            let feed = FeedMessage(cursor: req.cursor, cwd: req.cwd, buffer: req.buffer)
            guard let verdict = sessions.admit(session: session, feed) else { return "0" }
            panel.record(feed: req)
            state.updateRemote(feed)
            if verdict.changed, let app = verdict.appPID {
                panel.present(over: app, buffer: req.buffer)
            } else if req.buffer.isEmpty || !state.hasContent {
                panel.dismissPanel()
            } else {
                panel.scheduleIdleHide()
            }
            return "\(state.hasContent ? max(state.suggestions.count, 1) : 0)"
        case "up":
            guard ownsRemotePanel, state.selectedIndex > 0 else { return "PASS" }
            state.moveSelection(-1)
            panel.relayoutPanel()
            return "\(state.suggestions.count)"
        case "down":
            guard ownsRemotePanel else { return "PASS" }
            state.moveSelection(1)
            panel.relayoutPanel()
            return "\(state.suggestions.count)"
        case "accept":
            guard ownsRemotePanel else { return "" }
            if state.selectedIsExecute {
                panel.dismissPanel()
                return "EXEC"
            }
            guard let (b, c) = state.accept() else { return "" }
            panel.dismissPanel()
            return "\(c)\(TINE_US)\(b)"
        case "prefix":
            guard ownsRemotePanel, let (b, c) = state.commonPrefix() else { return "" }
            return "\(c)\(TINE_US)\(b)"
        case "dismiss":
            if sessions.isOwner(session) { panel.dismissPanel() }
            return "0"
        case "version":
            return version
        default:
            return "0"
        }
    }
}
