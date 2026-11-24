# Completion API

Tine.app answers completion requests from other apps over its unix socket, with
no panel and no tie to a shell or terminal. This is how a non-terminal input (an
editor's "bash mode" composer, say) shows tine's suggestions in its own popup.

## Connect

The socket is `~/.local/share/tine/tine.sock`. One connection carries one
request: write the request line, read one reply line, close.

If the connection is refused or the socket is missing, Tine isn't running. Start
it with `open -g -b dev.gustaf.tine` and retry for a couple of seconds; the
socket appears once the app has launched. A launch can still show Tine's own
windows: the dashboard when "open at start" is on, and the Accessibility prompt
until that is granted.

## Request

One line: five fields separated by US (`0x1f`), ending in `\n`. Byte for
byte, from a shell:

```sh
printf 'complete\x1f6\x1f%s\x1f\x1fgit ch\n' "$PWD" | nc -U ~/.local/share/tine/tine.sock
```

The fields, in order: the verb `complete`, `cursor`, `cwd`, an empty field,
and `buffer`.

- `cursor`: caret position in `buffer`, in UTF-16 code units (an `NSRange`
  location). Out-of-range values are clamped.
- `cwd`: absolute directory the command would run in. Path and file
  completions are relative to it.
- The empty field is where the terminal widget sends its screen position.
- `buffer`: the command line. It can't contain `\n`, so for a multi-line
  input send the line the caret is on, with `cursor` relative to that line, and
  add the line's offset back to the ranges in the reply.

## Reply

One line of JSON:

```json
{"version":1,"pending":false,"items":[
  {"name":"checkout","description":"Switch branches or restore working tree files",
   "kind":"subcommand","dangerous":false,"matches":[0,1],
   "edit":{"start":4,"end":6,"text":"checkout","cursor":12}}
]}
```

- `version`: the schema version, `1`. Fields may be added within a version;
  a removed or changed field bumps it.
- `pending`: a generator (git branches, a folder listing, ...) is still
  running, so `items` may be missing its results. Send the same request again
  after about 150 ms; the finished output is cached for 3 s.
- `items`: ranked best first. Empty means nothing to show.
  - `name`: the text to show. `matches` are the UTF-16 offsets in `name`
    that matched what was typed, for highlighting.
  - `description`: secondary text, may be empty.
  - `kind`: `subcommand`, `option`, `arg`, `file`, `folder`, `history`,
    `special`, `mixin` or `shortcut`. Treat any other value as a generic item.
  - `dangerous`: the spec marks this as destructive (`rm -rf` and friends).
  - `edit`: how to accept the item. Replace `buffer[start..<end]` (UTF-16
    offsets in the request's buffer) with `text`, then put the caret at
    `cursor`, which is already relative to the edited buffer. `text` is final:
    shell escaping and the trailing space are already applied.

A reply that doesn't start with `{` comes from a Tine.app too old to know
`complete`; treat it as "unsupported".

## Latency and cancelling

Requests are served one at a time on the app's main thread, shared with the
terminal widget. A command's first request loads its spec (20 to 50 ms); later
ones take 1 to 10 ms. An argument backed by a generator waits at most 60 ms on
its first run (replying `pending` if that wasn't enough), then is served from
cache.
There is no cancel verb: to drop a request, close its connection and ignore the
reply.

Completions use the PATH, aliases and history the zsh integration last sent;
the app keeps one of each, shared by every client. Without a zsh prompt sourcing
`tine.zsh`, generators see only launchd's minimal PATH. A client can set it
with the `path` verb (`path`, `0`, `cwd`, empty, then the PATH as the
buffer), but the next zsh prompt replaces it.

## Client checklist

- Put it behind an opt-in setting.
- Debounce keystrokes (30 to 50 ms), keep at most one request in flight, and
  drop replies for a buffer that has since changed.
- Show the popup when `items` is non-empty; hide it when the buffer is empty
  or a reply comes back empty.
- Up and Down move the selection, Tab accepts the selected item's `edit`, Esc
  hides the popup until the buffer changes.
- While `pending` is true and the buffer is unchanged, re-request a few times.
