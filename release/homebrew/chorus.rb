# Homebrew cask for Chorus. This file is the source of truth; copy it to
# `Casks/chorus.rb` in the nicojan/homebrew-tap repo on each release (see
# step 9 in ../DISTRIBUTION.md).
#
# `auto_updates true` tells Homebrew that Sparkle owns updates, so `brew upgrade`
# leaves an app that updated itself alone. Livecheck reads the same appcast the
# app does, which is what makes `brew bump-cask-pr` work.
cask "chorus" do
  version "1.5.16"
  sha256 "168ffc8b5935008597331a6d208fd02dbff24338168ea691bfb4eec7b45cb91c"

  url "https://github.com/nicojan/Chorus/releases/download/v#{version}/Chorus-#{version}.dmg"
  name "Chorus"
  desc "Multi-service web browser with an isolated session per account"
  homepage "https://github.com/nicojan/Chorus"

  # `&:short_version` keeps the cask on `1.5.16` rather than Sparkle's
  # `1.5.16,25` (shortVersionString plus the build number Sparkle compares), so
  # the release step has one number to bump.
  livecheck do
    url "https://nicojan.github.io/Chorus/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Chorus.app"

  # The SwiftData store is deliberately absent: release builds keep it at
  # `~/Library/Application Support/default.store`, SwiftData's unscoped default
  # (Chorus/App/AppState.swift), and that path is not specific to Chorus, so
  # trashing it could take another app's store with it. Add it here once the
  # store moves into a `Chorus/` subdirectory.
  zap trash: [
    "~/Library/Caches/com.nicojan.Chorus",
    "~/Library/HTTPStorages/com.nicojan.Chorus",
    "~/Library/Preferences/com.nicojan.Chorus.plist",
    "~/Library/Saved Application State/com.nicojan.Chorus.savedState",
    "~/Library/WebKit/com.nicojan.Chorus",
  ]
end
