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
| `teamID` | `ExportOptions.plist` | `3CY4DX3K45` |
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
   Runtime already enabled). Set the same Team ID in `ExportOptions.plist`.

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
     -exportOptionsPlist ExportOptions.plist -exportPath build/export
   ```

4. **Package a DMG** (e.g. with `create-dmg`, or `hdiutil`). Name it without
   spaces (`Chorus-X.Y.Z.dmg`) so the enclosure URL stays clean:
   ```sh
   create-dmg build/export/Chorus.app build/ --dmg-title "Chorus"
   mv "build/Chorus "*.dmg "build/Chorus-X.Y.Z.dmg"
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

7. **Sign + regenerate the appcast.** `generate_appcast` reads the EdDSA private
   key from your Keychain and writes signed `<item>` entries; point the enclosure
   URLs at the release you just created. The binary ships in the Sparkle
   distribution's `bin/` (or under DerivedData at
   `…/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast`):
   ```sh
   mkdir -p updates && cp build/Chorus-X.Y.Z.dmg updates/
   generate_appcast \
     --download-url-prefix "https://github.com/nicojan/Chorus/releases/download/vX.Y.Z/" \
     updates/
   cp updates/appcast.xml docs/appcast.xml
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

## Known gaps / future work

- **Camera/microphone**: entitlements + `NS*UsageDescription` strings are in
  place, but WKWebView won't grant capture to embedded services until a
  `WKUIDelegate` `webView(_:requestMediaCapturePermissionFor:…)` handler is
  implemented. Prepped, not yet active.
- **Passkeys (WebAuthn)**: gated off in `AppCapabilities.passkeysSupported`. The
  `com.apple.developer.web-browser.public-key-credential` entitlement is
  Apple-managed and must be requested/granted before flipping it on (it also
  requires a provisioning profile that embeds it).
