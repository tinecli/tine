import Foundation

struct CarapaceInstall: Equatable {
    let path: String
    let descriptions: [String: String]
}

/// The shell sends PATH every prompt: rerun `carapace --list` only when the resolved binary changes.
final class CarapaceProbe {
    var onChange: ((CarapaceInstall?) -> Void)?
    private let queue = DispatchQueue(label: "dev.gustaf.tine.carapace", qos: .utility)
    private var stamp: String?

    func refresh(searchPath: String) {
        queue.async { [self] in
            let fm = FileManager.default
            let binary = searchPath.split(separator: ":").map { "\($0)/carapace" }
                .first { fm.isExecutableFile(atPath: $0) }
            let target = binary.map { ($0 as NSString).resolvingSymlinksInPath } ?? ""
            let modified = (try? fm.attributesOfItem(atPath: target))?[.modificationDate] as? Date
            let current = "\(binary ?? "")\u{1f}\(target)\u{1f}\(modified?.timeIntervalSince1970 ?? 0)"
            guard current != stamp else { return }
            stamp = current

            let install = binary.map { path in
                let output = CommandRunner.runOnce(executable: path, args: ["--list"], timeoutMs: 10_000)
                let completers = (try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)))
                    as? [String: Any] ?? [:]
                return CarapaceInstall(path: path, descriptions: completers.mapValues {
                    ($0 as? [[String: Any]])?.first?["description"] as? String ?? ""
                })
            }
            DispatchQueue.main.async { self.onChange?(install) }
        }
    }
}
