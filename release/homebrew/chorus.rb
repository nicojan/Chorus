# Homebrew cask for Chorus. This file is the source of truth; copy it to
# `Casks/chorus.rb` in the nicojan/homebrew-tap repo on each release (see
# step 9 in ../DISTRIBUTION.md).
#
# `auto_updates true` tells Homebrew that Sparkle owns updates, so `brew upgrade`
# leaves an app that updated itself alone. Livecheck reads the same appcast the
# app does, which is what makes `brew bump-cask-pr` work.
cask "chorus" do
  version "1.5.18"
  sha256 "75a85465e81f85f08b73ab5991e348e6a2ce32692f366011c9f695e5c3ad52c0"

  url "https://github.com/nicojan/Chorus/releases/download/v#{version}/Chorus-#{version}.dmg"
  name "Chorus"
  desc "Multi-service web browser with an isolated session per account"
  homepage "https://github.com/nicojan/Chorus"

  # `&:short_version` keeps the cask on `1.5.17` rather than Sparkle's
  # `1.5.17,26` (shortVersionString plus the build number Sparkle compares), so
  # the release step has one number to bump.
  livecheck do
    url "https://nicojan.github.io/Chorus/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Chorus.app"

  # The store moved into its own folder in 1.5.18, so it can finally be zapped.
  # It used to sit at `~/Library/Application Support/default.store`, SwiftData's
  # unscoped default, which is not specific to Chorus: another app that took the
  # same default writes to that exact file, and trashing it would have taken
  # that app's data with it. `Application Support/Chorus` is ours alone. The old
  # path is still deliberately absent for the same reason as before.
  zap trash: [
    "~/Library/Application Support/Chorus",
    "~/Library/Caches/com.nicojan.Chorus",
    "~/Library/HTTPStorages/com.nicojan.Chorus",
    "~/Library/Preferences/com.nicojan.Chorus.plist",
    "~/Library/Saved Application State/com.nicojan.Chorus.savedState",
    "~/Library/WebKit/com.nicojan.Chorus",
  ]
end
