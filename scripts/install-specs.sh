#!/bin/bash
# Install the spec pack to ~/.local/share/tine/specs (where the app loads it).
# Stand-in for the future `tine specs update` HTTP download — re-run to refresh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${TINE_SPECS_DIR:-$HOME/.local/share/tine/specs}"

[ -d "$ROOT/specs-pack" ] || bash "$ROOT/scripts/build-specs.sh"

echo "› installing spec pack → $DEST"
mkdir -p "$DEST"
rsync -a --delete "$ROOT/specs-pack/" "$DEST/"
clis=$(find "$DEST" -name '*.js' | sed -E "s#^$DEST/##; s#\.js\$##; s#/.*##" | sort -u | wc -l | tr -d ' ')
echo "› $clis CLIs ($(find "$DEST" -name '*.js' | wc -l | tr -d ' ') spec files) installed"

# Install the shell integration next to it (what ~/.zshrc sources).
cp "$ROOT/shell/tine.zsh" "$(dirname "$DEST")/tine.zsh"
echo "› shell integration → $(dirname "$DEST")/tine.zsh"
