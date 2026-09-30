import Foundation

/// Wire format (one line): `type US cursor US cwd US pos US buffer`; a shell predating
/// `session` sends six `pos` fields and reads as session 0 — field order/count is load-bearing.
struct Request {
    let type: String
    let cursor: Int
    let cwd: String
    let anchorRow: Int
    let anchorCol: Int
    let cols: Int
    let rows: Int
    let cellW: Int     // device pixels
    let cellH: Int     // device pixels
    var session: pid_t
    let buffer: String
}

/// `respond` runs on the main thread — it touches UI/AppState state directly. A nil reply closes without writing.
final class SocketServer {
    struct Limits {
        let maxLineBytes: Int
        let readTimeoutSeconds: Int
    }

    private let path: String
    private let limits: Limits?
    private let respond: (String) -> String?
    private var fd: Int32 = -1

    init(path: String, limits: Limits? = nil, respond: @escaping (String) -> String?) {
        self.path = path
        self.limits = limits
        self.respond = respond
    }

    convenience init(path: String, handler: @escaping (Request) -> String) {
        self.init(path: path) { line in Request(line: line).map(handler) }
    }

    func start() -> Bool {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { perror("tine socket"); return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cs in
                let dst = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dst, cs, sunPathSize - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { perror("tine bind"); return false }
        guard chmod(path, 0o600) == 0 else { perror("tine chmod"); return false }
        guard listen(fd, 16) == 0 else { perror("tine listen"); return false }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    private func acceptLoop() {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { break }
            handle(conn)
            close(conn)
        }
    }

    private func handle(_ conn: Int32) {
        if let limits {
            var timeout = timeval(tv_sec: limits.readTimeoutSeconds, tv_usec: 0)
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        readLoop: while true {
            let n = read(conn, &chunk, chunk.count)
            if n <= 0 && limits != nil { return }
            if n <= 0 { break }
            for i in 0..<n {
                if chunk[i] == 0x0a { break readLoop }
                data.append(chunk[i])
            }
            if let limits, data.count > limits.maxLineBytes { return }
        }
        guard let line = String(data: data, encoding: .utf8) else { return }

        var reply: String?
        DispatchQueue.main.sync { reply = respond(line) }
        guard let reply else { return }

        var out = Array((reply + "\n").utf8)
        _ = write(conn, &out, out.count)
    }
}

extension Request {
    init?(line: String) {
        let parts = line.components(separatedBy: TINE_US)
        guard parts.count >= 4 else { return nil }
        // Rejoined below with TINE_US: the buffer itself may contain that separator.
        let extended = parts.count >= 5
        let pos = extended ? parts[3].components(separatedBy: ";").map { Int($0) ?? 0 } : []
        func p(_ i: Int) -> Int { i < pos.count ? pos[i] : 0 }
        self.init(
            type: parts[0],
            cursor: Int(parts[1]) ?? 0,
            cwd: parts[2],
            anchorRow: p(0),
            anchorCol: p(1),
            cols: p(2),
            rows: p(3),
            cellW: p(4),
            cellH: p(5),
            session: pid_t(exactly: max(0, p(6))) ?? 0,
            buffer: parts[(extended ? 4 : 3)...].joined(separator: TINE_US)
        )
    }
}
