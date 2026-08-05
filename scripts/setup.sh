#!/usr/bin/env bash

set -e

OS="$(uname -s)"

install_macos_deps() {
  echo "Detected macOS"
  xcode-select --install || true
  brew install mise pnpm protobuf zsh jq
}

add_mise_to_shell() {
  echo "Adding mise integration to shell..."

  SHELL_NAME=$(basename "$SHELL")

  case "$SHELL_NAME" in
    zsh)
      ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
      grep -qxF 'eval "$(mise activate zsh)"' "$ZSHRC" || echo 'eval "$(mise activate zsh)"' >> "$ZSHRC"
      ;;
    bash)
      BASHRC="$HOME/.bashrc"
      grep -qxF 'eval "$(mise activate bash)"' "$BASHRC" || echo 'eval "$(mise activate bash)"' >> "$BASHRC"
      ;;
    fish)
      FISH_CONFIG="$HOME/.config/fish/config.fish"
      mkdir -p "$(dirname "$FISH_CONFIG")"
      grep -qxF 'mise activate fish | source' "$FISH_CONFIG" || echo 'mise activate fish | source' >> "$FISH_CONFIG"
      ;;
    *)
      echo "⚠️  Unknown shell '$SHELL_NAME'. Please add mise manually to your shell config."
      ;;
  esac
}

setup_mise() {
  echo "Installing Node with mise..."
  add_mise_to_shell
  mise trust
  mise install
}

install_js_deps() {
  echo "Installing JS dependencies..."
  # No --ignore-scripts: pnpm.onlyBuiltDependencies in package.json already
  # allowlists just @bufbuild/buf's postinstall (downloads the buf binary,
  # needed to build @tine/proto) and blocks everything else.
  pnpm install
}

build_workspace() {
  echo "Building workspace packages (packages/*/dist)..."
  pnpm run build
}

echo "Setting up project dependencies..."

if [[ "$OS" != "Darwin" ]]; then
  echo "Unsupported OS: $OS — tine is macOS only."
  exit 1
fi

install_macos_deps
setup_mise
install_js_deps
build_workspace

echo "✅ Setup complete! Follow the instructions in the README to get started."
