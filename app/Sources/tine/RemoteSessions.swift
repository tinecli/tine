import Foundation
import Security

/// Maps each `tine ssh` token to the local shell that asked for it. Main thread only.
final class RemoteSessions {
    private var sessions: [String: pid_t] = [:]
    private let isAlive: (pid_t) -> Bool

    init(isAlive: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 }) {
        self.isAlive = isAlive
    }

    var count: Int { sessions.count }

    func begin(session: pid_t) -> String? {
        guard session > 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        sessions = sessions.filter { isAlive($0.value) }
        sessions[token] = session
        return token
    }

    func end(token: String) {
        sessions[token] = nil
    }

    func session(for token: String) -> pid_t? {
        guard let session = sessions[token] else { return nil }
        guard isAlive(session) else {
            sessions[token] = nil
            return nil
        }
        return session
    }
}
