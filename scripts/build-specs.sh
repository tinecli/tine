#!/bin/bash
# Build the tine spec pack: convert every @withfig/autocomplete spec from ESM to
# CJS (so JSC can eval them via new Function), preserving the directory layout,
# plus the completions index. Output: specs-pack/  (gzip + host this; the app
# downloads/extracts it to ~/.local/share/tine/specs).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/node_modules/@withfig/autocomplete/build"
OUT="$ROOT/specs-pack"
ESBUILD="$ROOT/node_modules/.pnpm/@esbuild+darwin-arm64@0.25.3/node_modules/@esbuild/darwin-arm64/bin/esbuild"

[ -d "$SRC" ] || { echo "missing $SRC — run: corepack pnpm add -w -D @withfig/autocomplete"; exit 1; }

echo "› converting specs ESM → CJS → $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
# --bundle inlines the few specs that import helpers; self-contained ones pass through.
find "$SRC" -name '*.js' -print0 | xargs -0 "$ESBUILD" \
  --bundle --format=cjs --platform=node \
  --outdir="$OUT" --outbase="$SRC" --log-level=error

cp "$SRC/index.json" "$OUT/index.json"

# tine's own built-in specs (builtin-specs/*.js — e.g. the `tine` CLI itself):
# copy into the pack and register each in the completions index so they resolve
# like any other pack spec.
if ls "$ROOT/builtin-specs"/*.js >/dev/null 2>&1; then
  echo "› adding built-in specs"
  cp "$ROOT/builtin-specs"/*.js "$OUT/"
  node -e '
    const fs = require("fs");
    const [idxPath, dir] = process.argv.slice(1);
    const idx = JSON.parse(fs.readFileSync(idxPath, "utf8"));
    const set = new Set(idx.completions || []);
    for (const f of fs.readdirSync(dir)) if (f.endsWith(".js")) set.add(f.slice(0, -3));
    idx.completions = [...set];
    fs.writeFileSync(idxPath, JSON.stringify(idx));
  ' "$OUT/index.json" "$ROOT/builtin-specs"
fi

clis=$(find "$OUT" -name '*.js' | sed -E "s#^$OUT/##; s#\.js\$##; s#/.*##" | sort -u | wc -l | tr -d ' ')
echo "› $clis CLIs ($(find "$OUT" -name '*.js' | wc -l | tr -d ' ') spec files), $(du -sh "$OUT" | cut -f1)"
