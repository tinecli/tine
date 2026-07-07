# Homebrew cask for Tine. Copy this to gustaferiksson/homebrew-tap as
# Casks/tine.rb. The Release workflow keeps `version` + `sha256` in sync.
cask "tine" do
  version "0.1.0"
  sha256 "26c52ad918d41cec3cc70d98545d86371b31d0aa62789ef69952b933185d0452"

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
