import Foundation
import JavaScriptCore

struct Suggestion {
    let name: String
    let description: String
    let insertValue: String
    let shouldAddSpace: Bool
    let type: String      // subcommand | option | arg | folder | file | auto-execute | …
    let queryTerm: String // chars before the cursor this replaces (basename for paths)
    let isDangerous: Bool
    let matchIndices: [Int] // matched char positions in name (fuzzy), for highlighting

    // Fig's "auto-execute" row: run the line as-is (insertValue "\n").
    var isExecute: Bool { type == "auto-execute" }
}

/// Wraps the Fig autocomplete engine running in JavaScriptCore. Not thread-safe —
/// call on one thread (we use the main thread from the socket callback).
final class JSEngine {
    private let ctx = JSContext()!
    private(set) var ready = false

    init(specsDir: String, localSpecsDirs: [String], resourcesDir: String) {
        ctx.exceptionHandler = { _, exc in tlog("JS EXC: \(exc?.toString() ?? "?")") }

        // Synchronous file read for the spec loader (fread -> __tineReadFile).
        let readFile: @convention(block) (String) -> String = { path in
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }
        ctx.setObject(readFile, forKeyedSubscript: "__tineReadFile" as NSString)
        ctx.setObject(specsDir as NSString, forKeyedSubscript: "__tineSpecsDir" as NSString)
        // User's own spec locations (merged onto the pack). Create the
        // override/ + extend/ subfolders so it's obvious where specs go.
        for d in localSpecsDirs {
            try? FileManager.default.createDirectory(atPath: "\(d)/override", withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: "\(d)/extend", withIntermediateDirectories: true)
        }
        ctx.setObject(localSpecsDirs as NSArray, forKeyedSubscript: "__tineLocalSpecsDirs" as NSString)

        // Command bridge for dynamic generators (git branch, ls, file paths, ).
        let runCommand: @convention(block) (String) -> String = { CommandRunner.run($0) }
        ctx.setObject(runCommand, forKeyedSubscript: "__tineRun" as NSString)
        // HOME so the path generators expand `~` (e.g. `cd ~/`).
        ctx.setObject(NSHomeDirectory() as NSString, forKeyedSubscript: "__tineHome" as NSString)

        // Shims are baked into the bundle via esbuild --inject, so this is the
        // single self-contained artifact.
        let path = "\(resourcesDir)/tine-engine.js"
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            tlog("engine: missing \(path)")
            return
        }
        ctx.evaluateScript(src, withSourceURL: URL(fileURLWithPath: path))
        ready = ctx.objectForKeyedSubscript("tineSuggest")?.isUndefined == false
        tlog("engine ready=\(ready) specsDir=\(specsDir)")
    }

    struct Result {
        let searchTerm: String
        let items: [Suggestion]
    }

    /// Cache the shell's aliases so the parser can expand them (e.g. `pc` → `plug-cli`).
    func setAliases(_ aliases: [String: String]) {
        guard ready else { return }
        ctx.setObject(aliases as NSDictionary, forKeyedSubscript: "__tineAliases" as NSString)
    }

    /// Provide the frecency index ([cmd: [param: lastUsedMillis]]) for ranking.
    func setFrecency(_ index: [String: [String: Double]]) {
        guard ready else { return }
        ctx.setObject(index as NSDictionary, forKeyedSubscript: "__tineFrecency" as NSString)
    }

    /// Toggle first-token (command-name) completion.
    func setFirstTokenEnabled(_ on: Bool) {
        guard ready else { return }
        ctx.setObject(NSNumber(value: on), forKeyedSubscript: "__tineFirstToken" as NSString)
    }

    /// Synchronous because the spec read hook is synchronous, so the engine's
    /// promise chain drains within JSC's microtask flush before this returns.
    func suggest(line: String, cursor: Int, cwd: String) -> Result {
        guard ready else { return Result(searchTerm: "", items: []) }
        ctx.setObject(line as NSString, forKeyedSubscript: "__q_line" as NSString)
        ctx.setObject(cwd as NSString, forKeyedSubscript: "__q_cwd" as NSString)
        ctx.evaluateScript(
            "globalThis.__out=null; tineSuggest(__q_line, \(cursor), __q_cwd, function(r){ globalThis.__out=r; });"
        )
        guard let out = ctx.objectForKeyedSubscript("__out"), !out.isNull, !out.isUndefined else {
            return Result(searchTerm: "", items: [])
        }
        let searchTerm = out.objectForKeyedSubscript("searchTerm")?.toString() ?? ""
        let arr = out.objectForKeyedSubscript("items")?.toArray() as? [[String: Any]] ?? []
        let items = arr.map { d in
            Suggestion(
                name: d["name"] as? String ?? "",
                description: d["description"] as? String ?? "",
                insertValue: d["insertValue"] as? String ?? (d["name"] as? String ?? ""),
                shouldAddSpace: d["shouldAddSpace"] as? Bool ?? false,
                type: d["type"] as? String ?? "",
                queryTerm: d["queryTerm"] as? String ?? "",
                isDangerous: d["isDangerous"] as? Bool ?? false,
                matchIndices: (d["matchIndices"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            )
        }
        return Result(searchTerm: searchTerm, items: items)
    }
}
