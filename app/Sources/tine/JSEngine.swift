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

        // Shims are baked into the bundle (tine-engine.ts imports them), so this
        // is the single self-contained artifact.
        let path = "\(resourcesDir)/tine-engine.js"
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            tlog("engine: missing \(path)")
            return
        }
        ctx.evaluateScript(src, withSourceURL: URL(fileURLWithPath: path))
        ready = ctx.objectForKeyedSubscript("tineSuggest")?.isUndefined == false
        tlog("engine ready=\(ready) specsDir=\(specsDir)")
    }

    /// Cache the shell's aliases so the parser can expand them (e.g. `pc` → `plug-cli`).
    func setAliases(_ aliases: [String: String]) {
        guard ready else { return }
        ctx.setObject(aliases as NSDictionary, forKeyedSubscript: "__tineAliases" as NSString)
    }

    /// Provide the frecency index ([cmd: [param: {count, lastUsed}]]) for ranking.
    func setFrecency(_ index: [String: [String: Frecency.Use]]) {
        guard ready else { return }
        let bridged = index.mapValues {
            $0.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] }
        }
        ctx.setObject(bridged as NSDictionary, forKeyedSubscript: "__tineFrecency" as NSString)
    }

    /// Re-bridge one command's params after a pick. Accept happens per keystroke,
    /// so it must not walk the whole index; this is the same property write the
    /// full bridge performs for that key, over untouched siblings, so the result
    /// is the state `setFrecency` would leave. Dropped before the load-path
    /// bridge sets the global — that bridge already carries the pick.
    func setFrecencyCommand(_ cmd: String, params: [String: Frecency.Use]) {
        guard ready, let index = ctx.objectForKeyedSubscript("__tineFrecency"), index.isObject
        else { return }
        let bridged = params.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] }
        index.setObject(bridged as NSDictionary, forKeyedSubscript: cmd as NSString)
    }

    /// Provide the argument values learned from history ([cmd: [flag: [value: Use]]]),
    /// suggested when the spec has nothing for the current arg.
    func setHistoryValues(_ index: [String: [String: [String: Frecency.Use]]]) {
        guard ready else { return }
        let bridged = index.mapValues {
            $0.mapValues { $0.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] } }
        }
        ctx.setObject(bridged as NSDictionary, forKeyedSubscript: "__tineHistoryValues" as NSString)
    }

    /// Drop the cached specs so a spec written after launch (`tine learn`) is used
    /// on the next keystroke instead of after a restart.
    func resetSpecCache() {
        guard ready else { return }
        ctx.evaluateScript("if (typeof tineResetSpecs === 'function') tineResetSpecs();")
    }

    /// Toggle first-token (command-name) completion.
    func setFirstTokenEnabled(_ on: Bool) {
        guard ready else { return }
        ctx.setObject(NSNumber(value: on), forKeyedSubscript: "__tineFirstToken" as NSString)
    }

    /// Does this command line parse against the installed spec? `tine ask` puts
    /// a model's answer through the same parser the panel uses, so a flag the
    /// tool does not document never reaches the user.
    func validate(line: String) -> AskValidation {
        guard ready else { return .unchecked }
        ctx.setObject(line as NSString, forKeyedSubscript: "__v_line" as NSString)
        ctx.evaluateScript(
            "globalThis.__vout=null; tineValidate(__v_line, function(r){ globalThis.__vout=r; });")
        guard let out = ctx.objectForKeyedSubscript("__vout"), !out.isNull, !out.isUndefined,
              let result = out.toDictionary() as? [String: Any]
        else { return .unchecked }
        switch result["status"] as? String {
        case "ok": return .ok(dangerous: result["dangerous"] as? Bool ?? false)
        case "invalid": return .invalid(result["token"] as? String ?? "")
        default: return .unchecked
        }
    }

    /// The flags and subcommands a tool's spec documents — what the model is
    /// allowed to use when its first answer failed to parse.
    func outline(command: String) -> [String] {
        let line = "\(command) "
        return suggest(line: line, cursor: line.count, cwd: NSHomeDirectory())
            .filter { $0.type == "option" || $0.type == "subcommand" }
            .map { $0.name }
    }

    /// Synchronous because the spec read hook is synchronous, so the engine's
    /// promise chain drains within JSC's microtask flush before this returns.
    func suggest(line: String, cursor: Int, cwd: String) -> [Suggestion] {
        guard ready else { return [] }
        ctx.setObject(line as NSString, forKeyedSubscript: "__q_line" as NSString)
        ctx.setObject(cwd as NSString, forKeyedSubscript: "__q_cwd" as NSString)
        ctx.evaluateScript(
            "globalThis.__out=null; tineSuggest(__q_line, \(cursor), __q_cwd, function(r){ globalThis.__out=r; });"
        )
        guard let out = ctx.objectForKeyedSubscript("__out"), !out.isNull, !out.isUndefined else {
            return []
        }
        let arr = out.objectForKeyedSubscript("items")?.toArray() as? [[String: Any]] ?? []
        return arr.map { d in
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
    }
}
