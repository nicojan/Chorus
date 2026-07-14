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
| `SUFeedURL` | `Chorus/Info.plist` | `https://nicojan.github.io/Chorus/appcast.xml` |

### Hosting (GitHub)

The `nicojan/Chorus` repo is **public**. Updates are hosted from it:

- **Appcast** — `docs/appcast.xml` in this repo, served by **GitHub Pages**
  (source: `main` branch, `/docs` folder) at
  `https://nicojan.github.io/Chorus/appcast.xml`. This is the stable `SUFeedURL`.
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

6. **Publish the DMG as a GitHub Release** (the DMG host):
   ```sh
   gh release create vX.Y.Z build/Chorus-X.Y.Z.dmg \
     --repo nicojan/Chorus --title "Chorus X.Y.Z" --notes "Release notes…"
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
   Installed apps pick up the update on their next scheduled check (or via
   Check for Updates…).

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
