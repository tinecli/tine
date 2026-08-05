#!/usr/bin/env bash

set -e

OS="$(uname -s)"

install_macos_deps() {
  echo "Detected macOS"
  xcode-select --install || true
  brew install bun
}

install_js_deps() {
  echo "Installing JS dependencies..."
  # No dependency needs a postinstall script.
  bun install
}

typecheck() {
  echo "Typechecking the engine..."
  bun run build
}

echo "Setting up project dependencies..."

if [[ "$OS" != "Darwin" ]]; then
  echo "Unsupported OS: $OS — tine is macOS only."
  exit 1
fi

install_macos_deps
install_js_deps
typecheck

echo "✅ Setup complete! Follow the instructions in the README to get started."
