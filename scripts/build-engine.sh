#!/bin/bash
# Bundle the tine JS engine (Fig parser + suggestions) into one IIFE for the app's
# JavaScriptCore context. @tine/api-bindings is aliased to a stub so the proto/IPC
# transport is excluded. Output: app/engine/tine-engine.js
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AC="$ROOT/packages/autocomplete"
ESBUILD="$ROOT/node_modules/.bin/esbuild"
STUB="$AC/tine-stub-api-bindings.mjs"
OUT="$ROOT/app/engine/tine-engine.js"

echo "› bundling engine → $OUT"
(cd "$AC" && "$ESBUILD" tine-engine.ts \
  --bundle --format=iife --platform=browser \
  --alias:@tine/api-bindings="$STUB" \
  --inject:"$ROOT/app/engine/shims.js" \
  --outfile="$OUT")
echo "› $(wc -c < "$OUT") bytes"
