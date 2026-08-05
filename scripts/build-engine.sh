#!/bin/bash
# Bundle the tine JS engine (Fig parser + suggestions) into one IIFE for the app's
# JavaScriptCore context. Output: app/engine/tine-engine.js
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/engine/tine-engine.js"

echo "› bundling engine → $OUT"
cd "$ROOT/packages/engine"
bun build tine-engine.ts \
  --format=iife --target=browser \
  --outfile="$OUT"
echo "› $(wc -c < "$OUT") bytes"
