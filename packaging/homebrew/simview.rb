# Homebrew cask for SimView. It lives in the tap repository github.com/jowhg/homebrew-tap as
# Casks/simview.rb, so that `brew install --cask jowhg/tap/simview` works (after `brew trust jowhg/tap`). After each release, set
# `version` and `sha256` from the release job's summary (or SHA256SUMS in the release).
cask "simview" do
  version "0.2.0"
  sha256 "67773ab8e2aa24960101dc4664859456a274229e1dd99c8737f9be914b58ef2f"

  url "https://github.com/jowhg/simview/releases/download/v#{version}/SimView-#{version}.zip"
  name "SimView"
  desc "All your iOS simulators in one window, plus an MCP server for AI agents"
  homepage "https://github.com/jowhg/simview"

  depends_on arch: :arm64
  depends_on formula: "mobai-app/tap/simslim"
  depends_on macos: :sonoma

  app "SimView.app"
  binary "#{appdir}/SimView.app/Contents/Helpers/simview-mcp"

  zap trash: [
    "~/Library/Preferences/io.github.jowhg.simview.plist",
    "~/Library/Saved Application State/io.github.jowhg.simview.savedState",
  ]

  caveats <<~EOS
    SimView needs Xcode 27 with the iOS simulator runtime.
    It is not notarized: the first time, open it, then allow it in
    System Settings > Privacy & Security > "Open Anyway".
    MCP server: `claude mcp add simview -- simview-mcp` (it is on your PATH).
  EOS
end
