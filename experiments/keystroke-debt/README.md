# keystroke debt

Your shell history is a bank statement. This reads it and tells you what your
typing habits cost you — then proposes the aliases that pay the debt back,
checked against every name your machine already answers to.

## Run it

```sh
bun experiments/keystroke-debt/debt.ts --sample
```

That reads the bundled sample history: no network, no subprocess, no user path.
Then audit your own (read-only, nothing is written anywhere):

```sh
bun experiments/keystroke-debt/debt.ts
```

```
  KEYSTROKE DEBT   statement · bundled sample
  ─────────────────────────────────────────────────────────────────────
  2,816 commands   ·   Nov 14, 2025 → Aug 10, 2026   ·   43,740 keystrokes
  That is 2h 26m of your life spent pressing keys at a prompt.

  REFINANCING PLAN
    alias  expands to                      typed                saves
    gst    git status                       384×  ▇▇▇▇▇▇▇▇▇▇▇   2,688
    dco    docker compose                   179×  ▇▇▇▇▇▇▇▇      1,969
    g      git                            1,321×  ▇▇▇▇▇▇▇▇      1,874
    gcm    git commit -m                    185×  ▇▇▇▇▇▇        1,480
    kgp    kubectl get pods                 107×  ▇▇▇▇▇▇        1,391
    gcma   git checkout main                 96×  ▇▇▇▇          1,056
    bt     bun test                         132×  ▇▇▇             792
    gpr    git pull --rebase                 58×  ▇▇▇             696

  11,946 keystrokes unspent over this history · 16,204/year ≈ 54m of typing a year

  COLLISIONS AVOIDED
    gs is already a command on this machine, so git status became gst.
    dc is already a command on this machine, so docker compose became dco.
    gcm went to 'git commit -m' above, so git checkout main became gcma.

  DEAD ALIASES   you defined them, then never typed them
    gco='git checkout' — and typed git checkout the long way 201×
    k='kubectl' — and typed kubectl the long way 154×
    gl='git pull' — and typed git pull the long way 58×
    gd='git diff' — and typed git diff the long way 54×

  PASTE ME   ~/.zshrc
    alias gst='git status'
    ...
```

## Flags

| flag | what it does |
| --- | --- |
| `--sample` | audit the bundled sample history — instant, offline, always the same |
| `--history <path>` | audit a history file somewhere else |
| `--top <n>` | how many aliases to propose (default 8, max 20) |
| `--help` | the above |

`NO_COLOR` is respected, and colour is off whenever stdout is not a terminal.

## How it decides

1. **Parse.** zsh's extended format (`: <epoch>:<seconds>;<command>`), plain
   lines, multi-line entries, and the "metafied" high bytes zsh writes for
   non-ASCII. Every command-word position counts, so `git add . && git commit`
   is two commands and a `;` inside quotes is not a separator.
2. **Propose phrases.** Prefixes of up to three tokens where every token is one
   you retype verbatim — a command word or a flag. Paths, quoted strings, hashes
   and ids are per-invocation noise and end the phrase.
3. **Name them.** Initials first, then more of the last word: `gs`, `gst`,
   `gsta`. The first rung that no command, builtin, function, reserved word,
   existing alias or earlier line of the plan already owns wins. In `--sample`
   mode those names come from a bundled list; otherwise from your own shell
   (`print -lr -- ${(k)commands} …`).
4. **Price them.** Each occurrence pays out once. Adding `gst` on top of `g`
   earns only the difference, so the plan can suggest both without billing the
   same keystrokes twice, and the column adds up to the total.
5. **Forget the past.** A command last typed over 180 days ago is a habit you
   dropped, not one worth an alias.
6. **Read your aliases back.** An alias you defined but have never once typed,
   while typing its expansion by hand, is dead — and more interesting than any
   alias this tool could invent.

## Known edges

- Nothing is ever written, so a missing history file exits 0 with a hint rather
  than failing. That is deliberate: this repo's lint rules bar the `process`
  global, and an exit code was not worth a nested lint config.
- Live mode shells out to `zsh -i -c` twice (4s timeout each) to learn which
  names are taken. If that fails, you still get the report — just without the
  collision check.
- `--sample` measures "recent" from the fixture's own last entry, so the demo
  reads the same in 2030 as it does today.

## Tests

```sh
bun test experiments/keystroke-debt
```

37 tests: parsing (extended, plain, folded, metafied), the quote-aware command
splitter, alias naming and collisions, the pay-once pricing model, the recency
filter, dead-alias detection, and the sample statement end to end.
