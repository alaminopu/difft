cask "difft" do
  version "0.3.1"
  sha256 "721fbb56a963e3399a9e971ae61f535ccc1a3c6fc145ecbfffdc3fbe4d547a5f"

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
