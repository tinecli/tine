#!/bin/bash
# Bundle the tine JS engine (Fig parser + suggestions) into one IIFE for the app's
# JavaScriptCore context. The "tine-jsc" export condition swaps @tine/api-bindings
# for its stub, so the proto/IPC transport stays out. Output: app/engine/tine-engine.js
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/engine/tine-engine.js"

echo "› bundling engine → $OUT"
cd "$ROOT/packages/autocomplete"
bun build tine-engine.ts \
  --format=iife --target=browser --conditions=tine-jsc \
  --outfile="$OUT"
echo "› $(wc -c < "$OUT") bytes"
