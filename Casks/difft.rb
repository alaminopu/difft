cask "difft" do
  version "0.4.0"
  sha256 "04fbcfd86ba8a76c472b55a29927ebbeaa0fb2b235a2ba5037d3426e9f47ffd9"

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
