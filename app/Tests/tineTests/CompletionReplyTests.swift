import Foundation
import Testing

struct CompletionReplyTests {
    static let script = """
    function item(o) {
      return Object.assign({name: 'x', description: '', insertValue: 'x', shouldAddSpace: false,
        type: 'arg', queryTerm: '', isDangerous: false, matchIndices: [1]}, o);
    }
    globalThis.tineSuggest = function(line, cursor, cwd, cb) {
      const rows = {
        'git --ve': [item({name: '--verbose', insertValue: '--verbose', shouldAddSpace: true,
          type: 'option', queryTerm: '--ve'})],
        'cd app/So': [item({name: 'Sources/', insertValue: 'Sources/', queryTerm: 'So', type: 'folder'})],
        'git --na': [item({insertValue: '--name={cursor}', queryTerm: '--na'})],
        'echo \u{1F389} --ve': [item({insertValue: '--verbose', queryTerm: '--ve'})],
        'ls': [item({description: String(cursor), queryTerm: 'ls'})],
        'mixed': [item({name: 'keep'}), item({name: 'run', type: 'auto-execute'}),
          item({name: 'learn', type: 'learn-it'})],
      };
      cb({items: rows[line] || []});
    };
    """

    func reply(_ buffer: String, cursor: Int? = nil) throws -> (raw: String, json: [String: Any]) {
        let root = Scratch.dir("completion-reply")
        let resources = root + "/resources"
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        try Self.script.write(
            toFile: resources + "/tine-engine.js", atomically: true, encoding: .utf8)
        let engine = JSEngine(
            specsDir: root + "/pack", localSpecsDirs: [], resourcesDir: resources,
            logPath: root + "/tine.log")

        let raw = CompletionReply(
            engine: engine, buffer: buffer, cursor: cursor ?? buffer.utf16.count, cwd: root).json
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return (raw, json)
    }

    func edit(_ json: [String: Any]) throws -> [String: Any] {
        let items = try #require(json["items"] as? [[String: Any]])
        return try #require(items.first?["edit"] as? [String: Any])
    }

    @Test func optionAndPathItemsReplaceTheQueryTermAndPlaceTheCursorAfterTheInsert() throws {
        let option = try edit(reply("git --ve").json)
        #expect(option["start"] as? Int == 4)
        #expect(option["end"] as? Int == 8)
        #expect(option["text"] as? String == "--verbose ")
        #expect(option["cursor"] as? Int == 14)

        let path = try edit(reply("cd app/So").json)
        #expect(path["start"] as? Int == 7)
        #expect(path["end"] as? Int == 9)
        #expect(path["text"] as? String == "Sources/")
        #expect(path["cursor"] as? Int == 15)
    }

    @Test func cursorMarkerUtf16OffsetsAndClampingFollowTheBuffer() throws {
        let marker = try edit(reply("git --na").json)
        #expect(marker["text"] as? String == "--name=")
        #expect(marker["cursor"] as? Int == 4 + 7)

        let emoji = "echo \u{1F389} --ve"
        let wide = try edit(reply(emoji).json)
        #expect(wide["start"] as? Int == emoji.utf16.count - 4)
        #expect(wide["end"] as? Int == emoji.utf16.count)

        let clamped = try reply("ls", cursor: 99).json
        let items = try #require(clamped["items"] as? [[String: Any]])
        #expect(items.first?["description"] as? String == "2")
        #expect(items.first.flatMap { $0["edit"] as? [String: Any] }?["end"] as? Int == 2)
    }

    @Test func panelOnlyRowsAreOmittedAndTheReplyIsOneVersionedLine() throws {
        let (raw, json) = try reply("mixed")

        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["name"] as? String } == ["keep"])
        #expect(json["version"] as? Int == 1)
        #expect(!raw.contains("\n"))
    }
}
