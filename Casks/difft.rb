cask "difft" do
  version "0.1.0"
  sha256 "1c87f53ba0ba46c19f4da10adfec551e4f18a68fca277b8bb1e7aac8460382dc"

  url "https://github.com/alaminopu/difft/releases/download/#{version}/Difft-#{version}.zip"
  name "Difft"
  desc "Native macOS app for reviewing GitHub pull requests"
  homepage "https://github.com/alaminopu/difft"

  depends_on macos: ">= :sonoma"

  app "Difft.app"

  # Difft is ad-hoc signed rather than notarized, so Gatekeeper would refuse
  # to open it after a download. Homebrew clears the quarantine flag itself
  # when a cask declares the app is unsigned.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Difft.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Difft",
    "~/Library/Preferences/dev.alaminopu.difft.plist",
  ]
end
