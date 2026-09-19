cask "difft" do
  version "0.4.2"
  sha256 "421e8782bd904946f3b3e242ec8267014b8e5116a204777bdc464176d4af00aa"

  url "https://github.com/alaminopu/difft/releases/download/#{version}/Difft-#{version}.zip"
  name "Difft"
  desc "Native macOS app for reviewing GitHub pull requests"
  homepage "https://github.com/alaminopu/difft"

  depends_on macos: :sonoma

  app "Difft.app"

  # Difft is signed with an Apple Development certificate rather than a
  # notarized Developer ID, so macOS quarantines it and Gatekeeper refuses to
  # open it. Install with --no-quarantine. A cask that cleared the flag itself
  # would be defeating Gatekeeper on the user's behalf without them asking.

  zap trash: [
    "~/Library/Application Support/Difft",
    "~/Library/Preferences/dev.alaminopu.difft.plist",
  ]
end
