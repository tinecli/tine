# @tine/fuzzysort

Fuzzy string matching for the autocomplete suggestion list. Zero dependencies.

`single(search, target)` returns `{ score, target, indexes }`, or `null` when the
search string is not a subsequence of the target. Scores are integers where `0`
is a perfect match and lower is worse: exact beats prefix, prefix beats a match
at a word boundary, a word boundary beats a match inside a word, and a
contiguous match beats a scattered one. `indexes` lists the matched target
positions, for highlighting.
