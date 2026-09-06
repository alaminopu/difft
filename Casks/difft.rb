cask "difft" do
  version "0.1.1"
  sha256 "a6ad42cfa9b92066d2623c48561534ff52a2f8e120c793a5e7303034d41b6019"

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
