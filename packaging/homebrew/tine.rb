# Homebrew cask for Tine. Copy this to gustaferiksson/homebrew-tap as
# Casks/tine.rb. The Release workflow keeps `version` + `sha256` in sync.
cask "tine" do
  version "0.1.3"
  sha256 "765b91141e5bd7ad2c5d6227cc93b278d6dc8332b580523184a8dc18f6a4baa8"

  url "https://github.com/gustaferiksson/tine/releases/download/v#{version}/Tine-#{version}.dmg"
  name "Tine"
  desc "Native macOS terminal autocomplete"
  homepage "https://github.com/gustaferiksson/tine"

  app "Tine.app"

  caveats <<~EOS
    Finish setup:
      echo 'source ~/.local/share/tine/tine.zsh' >> ~/.zshrc
    Then grant Accessibility: System Settings → Privacy & Security → Accessibility.
    Tine is signed but not notarized — on first launch, right-click the app → Open.
  EOS
end
