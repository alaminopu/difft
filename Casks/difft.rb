cask "difft" do
  version "0.3.0"
  sha256 "3423b8d009178ef4c9b4f81e4f4e85822f2dd4a039c30f4f545d7f89562b9567"

  url "https://github.com/alaminopu/difft/releases/download/#{version}/Difft-#{version}.zip"
  name "Difft"
  desc "Native macOS app for reviewing GitHub pull requests"
  homepage "https://github.com/alaminopu/difft"

  depends_on macos: :sonoma

  app "Difft.app"

  # Difft is ad-hoc signed rather than notarized, so macOS quarantines it and
  # Gatekeeper refuses to open it. Install with --no-quarantine. A cask that
  # cleared the flag itself would be defeating Gatekeeper on the user's behalf
  # without them asking.

  zap trash: [
    "~/Library/Application Support/Difft",
    "~/Library/Preferences/dev.alaminopu.difft.plist",
  ]
end
