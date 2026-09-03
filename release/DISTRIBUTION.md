# Distribution

Chorus ships via **direct distribution**: a Developer ID-signed, notarized
`.dmg`, with **Sparkle** handling in-app updates. It is **not** sandboxed and is
**not** distributed through the Mac App Store (a multi-service web browser runs
into App Review Guideline 4.2 / 5.2.1; direct distribution is the norm for this
category — Rambox, Shift, Ferdium, Wavebox all do the same).

Hardened Runtime stays **on** (required for notarization). The App Sandbox is
intentionally **off** — see `Chorus/Chorus.entitlements`.

---

## Configured values

These are set, reusing the WatchMeType setup (same Apple Developer account and
same Sparkle signing key):

| Key | Where | Value |
|---|---|---|
| `SUPublicEDKey` | `Chorus/Info.plist` | `6/h2Pfjbo39vHie8JIt/kY7h0wQvmQxj9Ea0W3gnH0w=` — verified to match the ed25519 private key in your login Keychain |
| `teamID` | `release/ExportOptions.plist` | `3CY4DX3K45` |
| `SUFeedURL` | `Chorus/Info.plist` | `https://updates.nicojan.com/chorus/appcast.xml` (1.5.20 and later; earlier builds use `https://nicojan.github.io/Chorus/appcast.xml`) |

### Hosting (GitHub)

The `nicojan/Chorus` repo is **public**. Updates are hosted from it:

- **Appcast** — `docs/appcast.xml` in this repo, served by **GitHub Pages**
  (source: `main` branch, `/docs` folder) at
  `https://nicojan.github.io/Chorus/appcast.xml`.
- **Appcast, again** — a Cloudflare Worker (`release/appcast-worker`) passes that
  same file through at `https://updates.nicojan.com/chorus/appcast.xml` and counts
  how many copies of Chorus check each day. That is the `SUFeedURL` from 1.5.20 on.
  Releasing does not change: commit `docs/appcast.xml` as before and the Worker
  picks it up within five minutes. **Never take the Pages URL down** — every build
  up to 1.5.19 asks it for updates and always will.
- **DMGs** — attached as **GitHub Release assets** (one release per version,
  tag `vX.Y.Z`). The appcast's `<enclosure>` URLs point at the release download
  URLs. Binaries don't bloat the git repo.

### Signing key note

The EdDSA **private** key already lives in your login Keychain (shared with
WatchMeType). Only the public key is in `Info.plist`. Keep that private key
backed up — if it's lost you cannot ship signed updates to existing users.

---

## One-time project setup

1. **Add the Sparkle package** — Xcode > File > Add Package Dependencies… >
   `https://github.com/sparkle-project/Sparkle` (use the latest 2.x). Add the
   `Sparkle` product to the **Chorus** target. The updater code in
   `Chorus/App/Updater.swift` and `ChorusApp.swift` is gated on
   `canImport(Sparkle)` and activates automatically once the package is present —
   no code changes needed. The "Check for Updates…" item then appears in the
   Chorus app menu.

2. **Signing** — in the Chorus target's Signing & Capabilities, set your Team and
   ensure the release build signs with **Developer ID Application** (Hardened
   Runtime already enabled). Set the same Team ID in `release/ExportOptions.plist`.

---

## Cutting a release

Run from the repo root. Replace `X.Y.Z` with the new version.

1. **Bump the version** (both must increase; `CURRENT_PROJECT_VERSION` is what
   Sparkle compares):
   - `MARKETING_VERSION` → `X.Y.Z` (user-facing, `CFBundleShortVersionString`)
   - `CURRENT_PROJECT_VERSION` → next integer (`CFBundleVersion`)

   Edit in Xcode (target build settings) or via `agvtool`.

2. **Archive:**
   ```sh
   xcodebuild -project Chorus.xcodeproj -scheme Chorus \
     -configuration Release -archivePath build/Chorus.xcarchive archive
   ```

3. **Export with Developer ID:**
   ```sh
   xcodebuild -exportArchive -archivePath build/Chorus.xcarchive \
     -exportOptionsPlist release/ExportOptions.plist -exportPath build/export
   ```

4. **Package a DMG.** The installed `create-dmg` is the create-dmg/create-dmg
   shell tool, and its syntax puts the output name first:
   `create-dmg [options] <output.dmg> <source_folder>`. (Earlier notes here used
   the argument order of a different tool of the same name, so the command
   failed.) Stage the notarized, stapled app into a clean
   folder, then build a drag-to-Applications image named without spaces
   (`Chorus-X.Y.Z.dmg`) so the enclosure URL stays clean:
   ```sh
   rm -rf build/dmg-src && mkdir -p build/dmg-src
   cp -R Chorus.app build/dmg-src/Chorus.app
   create-dmg --volname "Chorus" --window-size 600 320 --icon-size 100 \
     --icon "Chorus.app" 160 155 --app-drop-link 440 155 \
     build/Chorus-X.Y.Z.dmg build/dmg-src
   ```
   The tool lays the window out with AppleScript, so it needs a logged-in GUI
   session. Without one, fall back to `hdiutil create -volname "Chorus"
   -srcfolder build/dmg-src -ov -format UDZO build/Chorus-X.Y.Z.dmg`. Then sign
   the DMG so it carries your identity:
   ```sh
   codesign --force --sign "Developer ID Application: … (TEAMID)" build/Chorus-X.Y.Z.dmg
   ```

5. **Notarize and staple** (one-time: store creds with
   `xcrun notarytool store-credentials`):
   ```sh
   xcrun notarytool submit build/Chorus-X.Y.Z.dmg \
     --keychain-profile "chorus-notary" --wait
   xcrun stapler staple build/Chorus-X.Y.Z.dmg
   ```

### If you stop here, the DMG has a shelf life

Steps 2 to 5 publish nothing, so it is reasonable to build the artifact, check it
by hand, and leave the rest for later. Chorus 1.5.19 was held that way on
2026-08-29.

The cost is that the DMG is a build of one commit, and `main` keeps moving.
Publishing a stale one does not fail: it works, and ships code nobody reviewed as
the release. So before step 6, either confirm `main` is where it was when you
built, or build again.

Rebuilding is cheap. Steps 2 to 5 run in a few minutes, most of it waiting on the
notary service, and the version and build numbers do not need touching if nothing
was published under them. The sha256 changes, which matters at step 9 because the
Homebrew cask carries it.

Check the changelog date as well. The heading records the day the release was
cut, and a release held for a week ships with a date that is a week wrong, in a
file users read.

### Test builds while a release is held

A held release can absorb more work, and each round of it wants an artifact someone can install and try. Three things keep those from being mistaken for the release.

Move `CURRENT_PROJECT_VERSION` and leave `MARKETING_VERSION` alone. Nothing was published under any of these numbers, so the version does not need to move, but the About panel has to be able to tell one build from another when a tester reports something.

Name the file `Chorus-X.Y.Z-bNN.dmg`. The published artifact is `Chorus-X.Y.Z.dmg`, and a test build that reuses the name overwrites the one already notarised and stapled.

Package with `hdiutil` rather than `create-dmg`. The layout tool drives Finder through AppleScript, so it takes the screen for as long as it runs, which is a poor trade on a machine someone is working on. The published artifact should still be built the documented way, since that is the one people see.

A test build is still a branch build. Merge before cutting anything from it, and rebuild from the merged commit.

### Before step 6, finish the by-hand pass

`docs/internal/VERIFY-BY-HAND.md` is that pass, and its Start here block says what is still unchecked. Steps 2 to 5 publish nothing, so stopping after them is fine. Step 6 is the first one users see. A tick in that file against an older build is not a tick against this one. A rebuild makes a new binary, and the checks are owed again.

6. **Push `main` first, then publish the DMG as a GitHub Release** (the DMG host):
   ```sh
   git push origin main                      # do this BEFORE the next command
   gh release create vX.Y.Z build/Chorus-X.Y.Z.dmg \
     --repo nicojan/Chorus --title "Chorus X.Y.Z" --notes "Release notes…"
   ```
   **The push has to come first.** `gh release create` tags the *remote*
   default-branch HEAD, so with the version bump still sitting unpushed the tag
   lands on the previous release's commit and `vX.Y.Z` then points at source that
   is not what shipped. This has caught us twice (1.5.11 and 1.5.15).

   To repair it after the fact, move the tag to the bump commit and force-push
   just the tag; the release asset stays attached. This repo's git config rejects
   a lightweight `git tag -f`, so the tag must be annotated:
   ```sh
   git tag -f -a vX.Y.Z <bump-commit-sha> -m "Chorus X.Y.Z"
   git push origin vX.Y.Z --force
   git show vX.Y.Z:project.yml | grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION"
   ```

7. **Sign the DMG and add an appcast item by hand.** `generate_appcast` works but
   has seed-and-prune traps that can drop older entries; signing with
   `sign_update` and editing one `<item>` in is simpler and keeps full history.
   Run `sign_update` on the **final stapled** DMG. Stapling changes the bytes, so
   sign after step 6 rather than before. It reads the EdDSA key from your Keychain
   and prints the `edSignature` and `length`:
   ```sh
   …/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update build/Chorus-X.Y.Z.dmg
   ```
   Add a new `<item>` at the top of `docs/appcast.xml`, copying an existing item's
   shape: set `sparkle:version` to the build number and `sparkle:shortVersionString`
   to `X.Y.Z`, point the enclosure at
   `https://github.com/nicojan/Chorus/releases/download/vX.Y.Z/Chorus-X.Y.Z.dmg`,
   and paste in the `length` and `edSignature`. Put the release notes in a CDATA
   `<description>` so Sparkle's prompt shows what changed. Confirm the enclosure
   `length` equals the uploaded asset's size, then check the file:
   ```sh
   xmllint --noout docs/appcast.xml
   ```

8. **Commit the appcast** so GitHub Pages republishes it at `SUFeedURL`:
   ```sh
   git add docs/appcast.xml
   git commit -m "release: Chorus X.Y.Z appcast"
   git push
   ```
   Then confirm the deploy actually ran. On 1.5.18 the push matched the
   workflow's `docs/**` filter and the workflow was active, yet GitHub
   dispatched nothing, so the appcast stayed on the previous version and the
   livecheck in step 9 read the old number. If no run appears, publish it by
   hand. Do not move on until the served appcast shows the new version.
   ```sh
   gh run list --workflow pages.yml --limit 3 --repo nicojan/Chorus
   gh workflow run pages.yml --ref main --repo nicojan/Chorus   # only if none fired
   curl -s https://nicojan.github.io/Chorus/appcast.xml | grep -m1 "<title>1\."
   ```

   Installed apps pick up the update on their next scheduled check (or via
   Check for Updates…).

9. **Update the Homebrew cask** (see the next section for the tap itself):
   ```sh
   shasum -a 256 build/Chorus-X.Y.Z.dmg          # the stapled DMG you uploaded

   # In this repo — release/homebrew/chorus.rb is the source of truth:
   sed -i '' -E 's/version "[^"]+"/version "X.Y.Z"/; s/sha256 "[^"]+"/sha256 "NEW_SHA"/' \
     release/homebrew/chorus.rb

   # Copy into the tap clone and check it before pushing:
   cp release/homebrew/chorus.rb "$(brew --repo nicojan/tap)/Casks/chorus.rb"
   brew style nicojan/tap
   brew livecheck --cask nicojan/tap/chorus     # must print the new version
   brew audit --cask --online nicojan/tap/chorus
   ```
   Then commit both: `release/homebrew/chorus.rb` here, `Casks/chorus.rb` in the
   tap. Hash the **stapled** DMG — the one attached to the release — not the
   pre-notarization build, since stapling changes the bytes.

---

## Homebrew

Chorus installs with `brew install --cask nicojan/tap/chorus`, served from the
**`nicojan/homebrew-tap`** repo. The cask lives at `release/homebrew/chorus.rb`
in this repo and is copied into the tap on each release.

The tap is a repo named `homebrew-tap` with the cask at `Casks/chorus.rb` and
nothing else required. To recreate it from scratch:

```sh
brew tap-new nicojan/tap                      # local skeleton
TAP="$(brew --repo nicojan/tap)"
rm -rf "$TAP/Formula" "$TAP/.github"          # cask-only tap
mkdir -p "$TAP/Casks"
cp release/homebrew/chorus.rb "$TAP/Casks/chorus.rb"
git -C "$TAP" add -A && git -C "$TAP" commit -m "chorus 1.5.14"
gh repo create nicojan/homebrew-tap --public --source "$TAP" --push
```

Two stanzas carry weight. `auto_updates true` tells Homebrew that Sparkle owns
updates, so `brew upgrade` leaves an app that already updated itself alone —
without it the two updaters fight and Homebrew reinstalls over Sparkle's work.
The `livecheck` block reads the same appcast the app does, which is what makes
`brew livecheck` and `brew bump-cask-pr` work.

### Why not homebrew/cask

The central `homebrew/cask` tap requires notability: 75 stars, 30 forks, or 30
watchers — and **225 stars for a self-submission by the repo owner**
(`Package-Acceptance-Policy.md`). `nicojan/Chorus` sits at 24 stars, so a PR from
you gets closed. `brew audit --cask --online --new` reports this and nothing else,
so the cask is otherwise ready: the DMG is signed, notarized and stapled, it is
published by the developer, and the `chorus` token is free. Submit it once the
stars are there — or leave the tap in place, since the install command is the only
difference to users.

---

## Beta channel (optional)

For pre-release testing without TestFlight: host a second appcast (e.g.
`appcast-beta.xml`) and point beta builds' `SUFeedURL` at it, or use Sparkle
channels (`SUUpdater` channel + `--channel beta` on `generate_appcast`). Hand
testers the notarized DMG directly.

---

## Content blocklist

The ad/tracker blocker compiles a bundled rule list (`Chorus/Resources/hagezi-light.json`)
at launch; there is no runtime download, so list updates ship with each release.

To refresh it, run `scripts/convert_blocklist.sh` and commit the regenerated JSON.
The script downloads a pinned HaGezi "Light" release and converts it to Safari
content-blocker JSON with AdGuard's SafariConverterLib. Bump the pinned
`HAGEZI_REF` / `CONVERTER_REF` in the script deliberately.

**Licensing:** SafariConverterLib is GPLv3 and is used **only as a build tool** —
its JSON output is bundled; the library is never linked into the app. Do NOT add
it to `project.yml` `packages`, or Chorus (MIT) becomes a GPL derivative. HaGezi's
data is GPL-3.0; its attribution + source link ship in the About settings pane.

---

## Known gaps / future work

- **Camera/microphone**: shipped in 1.5.3. A `WKUIDelegate`
  `requestMediaCapturePermissionFor` handler grants capture from a per-service
  Allow, Ask, or Deny policy, with a global default and a mute-all command.
  First-party call vendors are trusted across their own domains so cross-domain
  calls work without a prompt.
- **Passkeys (WebAuthn)**: gated off in `AppCapabilities.passkeysSupported`. The
  `com.apple.developer.web-browser.public-key-credential` entitlement is
  Apple-managed and must be requested/granted before flipping it on (it also
  requires a provisioning profile that embeds it).
