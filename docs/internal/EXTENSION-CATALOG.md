# Extension catalog: design and survey

Status: being built on `feat/extension-catalog`, from `main` after #52 and #53 merged on 2026-11-13. Design written 2026-11-13; Nico's answers are under "Decided with Nico".

## The problem

Chorus can add an extension from a file, but then it never updates. Shipping extensions inside the app would fix updates only as often as Chorus ships, and most good extensions are GPL, which Chorus cannot bundle in a signed, notarized app.

## The decision

Settings > Extensions gets a short list of extensions we have tested. Picking one downloads it from its publisher, so Chorus never redistributes anyone's code. Chorus then checks the publisher once a day and installs new versions itself. "Add from file" and Safari extensions inside Mac apps stay as they are.

## How it works

**Catalog.** A JSON file in the app bundle, changed only with a Chorus release. Each entry: id, name, one line on what it does, category, licence, the source, the version we tested, and a note on known gaps. A list fetched from a server would let that server choose what code people run; the list changes rarely, so it ships with the app.

**Sources.** Two kinds:

- `github`: owner/repo plus an asset name pattern, such as `dist-chrome-*.zip`. The releases API gives each asset a `digest` (sha256). Skip drafts and prereleases. Bitwarden's repo holds several products, so its entry also needs a tag prefix (`browser-v`).
- `amo`: an addons.mozilla.org slug. `GET /api/v5/addons/addon/<slug>/` gives `current_version.version`, `file.url` and `file.hash` (sha256). Mozilla signs these packages.

Never the Chrome Web Store: Google offers no supported download for other browsers. Prefer a Chrome build from GitHub when there is one; Chrome builds sit closest to what WebKit expects, and `ExtensionCompatibility` was written against them.

**Install.** Download over HTTPS from the pinned source only, check the sha256, then the existing path: `WebExtensionLibrary.importPackage`, `inspect`, the permission sheet, `ExtensionCompatibility`. The record gains `catalogID` and `installedVersion`. The list is JSON in `Application Support/Chorus/Extensions`, outside SwiftData, so no schema change. Engine API changes go into `ENGINE.md`.

**Updates.** At launch and every 24 hours, ask each catalog extension's source for its latest version. If it is newer, download, verify and import it into a new folder, then compare what it asks for with what the user granted:

- Nothing new: stage it. The next launch swaps the record's folder before loading. WebKit caches an extension's files when it loads, so a live swap would not take effect anyway.
- New permissions or sites: keep the old version running and show "Update needs your OK" on its row, with the same sheet as an install.
- Keep the old folder until the new one loads; if it fails, go back to the old one and log why.

Extension data has to survive an update. WebKit keys it by the context's `uniqueIdentifier` and `baseURL`, which both come from the record id, so keep the id. Check this with a test before relying on it.

A toggle, "Update extensions automatically", on by default. With it off, the row shows "Update available" and a button.

**Privacy.** The checks reveal to GitHub and Mozilla which catalog extensions someone uses, the same as any browser's updater. Send no identifier and a plain user agent. GitHub allows 60 unauthenticated calls an hour, far more than a daily check needs.

## Survey, 2026-11-13

Each package was imported through the real library and loaded by a throwaway engine test (kept in `.remember/tmp/extension-survey/`, not committed) with every permission it asks for, then shown a Wikipedia page for 8 s. "Errors" are what `WKWebExtensionContext.errors` collected, which includes uncaught errors in the background. Users are Firefox daily users from AMO, the only public count; Chrome counts are larger.

| Extension | Package tested | Licence | Firefox users | Result |
|---|---|---|---|---|
| Bitwarden | GitHub Chrome zip | GPL-3.0 | 1,044,031 | Works; fills and copies, checked by hand |
| SponsorBlock | GitHub Chrome zip | LGPL-3.0 | 824,045 | Works, checked by hand |
| Dark Reader | GitHub Chrome MV3 zip | MIT | 1,359,539 | Darkened the page; no errors |
| Return YouTube Dislike | GitHub Chrome zip | GPL-3.0 | 883,929 | No errors |
| uBlock Origin Lite | GitHub Chromium and Safari zips | GPL-3.0 | 22,311 | No errors; blocking not shown (see below) |
| Consent-O-Matic | GitHub Chromium zip | MIT | 136,299 | No errors |
| Obsidian Web Clipper | GitHub Chrome zip | MIT | 68,656 | No errors |
| Simple Translate | AMO | MPL-2.0 | 249,839 | No errors |
| To DeepL | AMO | MIT | 12,312 | No errors |
| Read Aloud | AMO | GPL-3.0 | 230,453 | No errors; speech not tried |
| DeArrow | GitHub Chrome zip | LGPL-3.0 | 34,530 | Works; one harmless error from messaging SponsorBlock |
| Raindrop.io | AMO | MPL-2.0 | 43,774 | Loads; WebKit rejects a keyboard command in its manifest |
| Proton Pass | AMO | GPL-3.0 | 197,273 | Background stops: no `runtime.onUpdateAvailable` |
| Violentmonkey | AMO | MIT | 207,380 | Background stops: no `notifications.onClicked` |
| LanguageTool | AMO | proprietary | 316,419 | Background fails to parse in JavaScriptCore (`¶` at line 26); no `storage.managed` |
| Grammarly | AMO | proprietary | 527,807 | Background errors and asks to talk to its Mac app |

uBlock Origin Lite's blocking could not be shown on this Mac: something outside WebKit already refuses the ad and tag-manager hosts (curl fails on them too), so the control without uBOL was blocked as well. Try it on a Mac without that filter, or with a test page whose blocked host this Mac lets through.

**Ruled out:**

- uBlock Origin, Privacy Badger, ClearURLs, Ghostery, DuckDuckGo, I Still Don't Care About Cookies: they block through `webRequestBlocking`, which WebKit does not have. uBlock Origin Lite and Chorus's own blocklist cover the same need.
- 1Password, KeePassXC: they need native messaging to their Mac app, which Chorus cannot pass on.
- Tampermonkey, Violentmonkey: user scripts overlap Custom JavaScript, which every service already has.
- Refined GitHub: publishes no release build ("for local testing only").
- Simplify Gmail: not on AMO; Chrome Web Store only.

## First catalog

Tested clean, in order of how useful they are in Chorus:

1. Bitwarden (passwords)
2. uBlock Origin Lite (blocking and cosmetic filtering, beyond Chorus's own list), once blocking is shown
3. Consent-O-Matic (answers cookie banners)
4. Simple Translate and To DeepL (translate a message in Slack, WhatsApp or Gmail)
5. Obsidian Web Clipper (save a page or message to a vault)
6. SponsorBlock, DeArrow, Return YouTube Dislike (for people who keep YouTube in Chorus)
7. Read Aloud (once speech is tried)

Add after a fix in `ExtensionCompatibility`, which already has the pattern: Proton Pass (stub `runtime.onUpdateAvailable`), Raindrop.io (check the bookmark button works despite the manifest warning). Violentmonkey stays out, and so does its `notifications.onClicked` stub (Nico, 2026-11-13).

Leave out Dark Reader: Chorus already offers Dark Reader per service, and two copies would fight.

## Decided with Nico, 2026-11-13

- The first catalog is the list above. The YouTube helpers stay in, listed last under their own category.
- uBlock Origin Lite comes from its Chrome build (`uBOLite_*.chromium.zip`), not the Safari one.
- "Update extensions automatically" is on by default. An update that asks for more still waits for the user's OK.
- The catalog gets a "Suggest an extension" link to a GitHub issue form that asks for the extension's name and its source.
- No Violentmonkey and no `notifications.onClicked` stub.

## Build order

1. Engine: `WebExtensionSource` (github, amo), a fetcher that returns version, URL and sha256, and download plus verify plus import. Tests with recorded API answers, no network.
2. Engine: record fields, staged swap at load, rollback, the permission comparison. A test that data survives a version swap.
3. App: the catalog JSON, a "Get extensions" section in Settings, the update toggle, "Update needs your OK", the "Suggest an extension" link and its issue form.
4. Compatibility stub for Proton Pass, with a probe test that fails first.
5. By hand in a Debug build: install, update (point an entry at an older tag first), refused update, rollback.
