import Foundation
import JavaScriptCore

struct Suggestion {
    let name: String
    let description: String
    let insertValue: String
    let shouldAddSpace: Bool
    let type: String
    let queryTerm: String
    let isDangerous: Bool
    let matchIndices: [Int]

    /// insertValue is "\n" for this row — treat as a name, not a literal, and it breaks execution.
    var isExecute: Bool { type == "auto-execute" }
}

/// JSContext is not thread-safe — call every method here only from the main thread.
final class JSEngine {
    private let ctx = JSContext()!
    private(set) var ready = false

    init(specsDir: String, localSpecsDirs: [String], resourcesDir: String) {
        ctx.exceptionHandler = { _, exc in tlog("JS EXC: \(exc?.toString() ?? "?")") }

        let readFile: @convention(block) (String) -> String = { path in
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }
        ctx.setObject(readFile, forKeyedSubscript: "__tineReadFile" as NSString)
        ctx.setObject(specsDir as NSString, forKeyedSubscript: "__tineSpecsDir" as NSString)
        for d in localSpecsDirs {
            try? FileManager.default.createDirectory(atPath: "\(d)/override", withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: "\(d)/extend", withIntermediateDirectories: true)
        }
        ctx.setObject(localSpecsDirs as NSArray, forKeyedSubscript: "__tineLocalSpecsDirs" as NSString)

        let runCommand: @convention(block) (String) -> String = { CommandRunner.run($0) }
        ctx.setObject(runCommand, forKeyedSubscript: "__tineRun" as NSString)
        ctx.setObject(NSHomeDirectory() as NSString, forKeyedSubscript: "__tineHome" as NSString)

        let path = "\(resourcesDir)/tine-engine.js"
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            tlog("engine: missing \(path)")
            return
        }
        ctx.evaluateScript(src, withSourceURL: URL(fileURLWithPath: path))
        ready = ctx.objectForKeyedSubscript("tineSuggest")?.isUndefined == false
        tlog("engine ready=\(ready) specsDir=\(specsDir)")
    }

    func setAliases(_ aliases: [String: String]) {
        guard ready else { return }
        ctx.setObject(aliases as NSDictionary, forKeyedSubscript: "__tineAliases" as NSString)
    }

    func setFrecency(_ index: [String: [String: Frecency.Use]]) {
        guard ready else { return }
        let bridged = index.mapValues {
            $0.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] }
        }
        ctx.setObject(bridged as NSDictionary, forKeyedSubscript: "__tineFrecency" as NSString)
    }

    /// Must match the shape a full `setFrecency` reload would produce, or ranking silently drifts.
    func setFrecencyCommand(_ cmd: String, params: [String: Frecency.Use]) {
        guard ready, let index = ctx.objectForKeyedSubscript("__tineFrecency"), index.isObject
        else { return }
        let bridged = params.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] }
        index.setObject(bridged as NSDictionary, forKeyedSubscript: cmd as NSString)
    }

    func setProjectFrecency(_ index: Frecency.Index) {
        guard ready else { return }
        let bridged = index.mapValues {
            $0.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] }
        }
        ctx.setObject(bridged as NSDictionary,
                      forKeyedSubscript: "__tineProjectFrecency" as NSString)
    }

    func setProjectFrecencyCommand(_ cmd: String, params: [String: Frecency.Use]) {
        guard ready,
              let index = ctx.objectForKeyedSubscript("__tineProjectFrecency"),
              index.isObject else { return }
        let bridged = params.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] }
        index.setObject(bridged as NSDictionary, forKeyedSubscript: cmd as NSString)
    }

    func setHistoryValues(_ index: [String: [String: [String: Frecency.Use]]]) {
        guard ready else { return }
        let bridged = index.mapValues {
            $0.mapValues { $0.mapValues { ["count": Double($0.count), "lastUsed": $0.lastUsed] } }
        }
        ctx.setObject(bridged as NSDictionary, forKeyedSubscript: "__tineHistoryValues" as NSString)
    }

    func resetSpecCache() {
        guard ready else { return }
        ctx.evaluateScript("if (typeof tineResetSpecs === 'function') tineResetSpecs();")
    }

    func setFirstTokenEnabled(_ on: Bool) {
        guard ready else { return }
        ctx.setObject(NSNumber(value: on), forKeyedSubscript: "__tineFirstToken" as NSString)
    }

    /// Model output must go through this same parser — never trust it via a shortcut path.
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

    /// Only what the spec documents — never widen this with convenience flags.
    func outline(command: String) -> [String] {
        let line = "\(command) "
        return suggest(line: line, cursor: line.count, cwd: NSHomeDirectory())
            .filter { $0.type == "option" || $0.type == "subcommand" }
            .map { $0.name }
    }

    /// Looks callback-based but is synchronous in practice — JSC drains the promise
    /// chain's microtasks before this returns. Don't wrap this in async expecting a real yield.
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
