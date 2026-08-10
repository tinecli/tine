import Foundation

/// Dead-simple file logger for development. Writes to /tmp/tine.log so it can be
/// read regardless of unified-log quirks. Replace with os_log later.
enum TineLog {
    static let path = "/tmp/tine.log"

    static func reset() {
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func write(_ msg: String, to path: String = TineLog.path) {
        let line = "\(Date()) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

func tlog(_ msg: String) { TineLog.write(msg) }
