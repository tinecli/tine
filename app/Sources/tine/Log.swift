import Foundation

/// Writes to /tmp/tine.log instead of the unified log so entries are readable without Console.app filters.
enum TineLog {
    static let path = "/tmp/tine.log"

    static func reset() {
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func write(_ msg: String) {
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
