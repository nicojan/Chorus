# Extension catalog: design and survey

Status: built on `feat/extension-catalog`, from `main` after #52 and #53 merged on 2026-11-13; all five steps of the build order are done (2026-11-14), the checks left open passed by hand on 2026-11-15 (step 6), and the rest on 2026-11-16 (step 7). Design written 2026-11-13; Nico's answers are under "Decided with Nico".

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

`testDataSurvivesAVersionSwap` checks this in one process: after the swap, version 2.0 reads what 1.0 wrote through `chrome.storage.local`, `localStorage` and IndexedDB, and a record with a new id reads none of it. Whether the data reaches disk across a relaunch is left to the by-hand pass.

**What rollback catches.** A trial rolls back when WebKit cannot read the manifest, the load fails, or the background fails to start. A staged folder that is gone at launch, swept by an older Chorus or deleted by hand, drops the update without skipping its version, before any trial. WebKit never answers `loadBackgroundContent` for a service worker that throws while it starts. It does record its `backgroundContentFailedToLoad` error in the context's `errors` within half a second, on macOS 15, 26 and 27.2; the host stops waiting when that error appears, and the trial rolls back on that one code. Other listed errors do not count, since Raindrop and DeArrow run fine with errors listed. `testBrokenBackgroundRollsBack` pins this, and `testBackgroundFailureRollsBack` covers a start that fails outright, through a test hook on the host. Trials run one at a time, so a version that crashes Chorus as it loads is the only one its attempt marker blames. Plain loads run beside a trial, and a crash during one of them counts against the trial.

**After a rollback the old version waits 12 s.** When the failed version unloads, WebKit keeps its origin's service worker process for 10 s more (`defaultTerminationDelay` in `SWServer`). A worker started on that origin in that time fails too, and holds the process another 10 s. The old version used to load at once, so it ran with no background for the rest of the session. Now the host notes when a context whose background failed unloads, and the next load of that id waits until 12 s after it; the extension keeps its id, and so its data. The wait holds nothing: turning the extension off and on during it leaves it running, and removing it reaches its data at once, since removal starts no background. One case does hold other work: an extension turned back on during the wait with a ready update waits there inside its trial, and trials queued behind it wait too. That can only happen during a session, never at launch. A broken update costs its user about 12 s at the launch that tries it. Other extensions no longer wait for it, but pages do, since they wait for `startEnabled`, and that stays. WebKit injects a newly loaded extension's content scripts into pages already open (probe, 2026-11-16). On macOS 15 and 26 it drops a content script's message that arrives while the background is still starting, so loading the old version after pages open would lose those messages. WebKit offers no public way to end this sooner: removing the store's service worker data does not free the origin and stops every other extension's worker, and asking for the background again fails the same way. `testOldVersionsBackgroundRunsAfterRollback` checks that the old worker answers a content script.

**A swap is an update to the extension.** The record keeps its id, so the new version starts with the old one's data and gets `runtime.onInstalled` with reason "update" and the old version as `previousVersion`. `WebExtensionInstallEventTests` pins this across three launches, and CI passes it on macOS 15 and 26. WebKit picks the reason as it loads a context (`determineInstallReasonDuringLoad`). A changed version always gets "update". For 5 s after the controller is made (`freshlyCreatedTimeout`), any other load counts as the browser starting and gets `runtime.onStartup`. After those 5 s, a load whose version did not change gets "install", even for an extension installed long ago. Chorus makes its controller at launch. Until 2026-11-16 it loaded extensions one at a time, each waiting for its background. Four of them (Bitwarden, Proton Pass, Consent-O-Matic, uBlock Origin Lite) finished 2.4 s after the controller on each of three launches, so a slow background, a rollback or a longer list would have pushed the rest past the 5 s. `startEnabled` now loads them all together, and only staged-update trials wait for each other. In `ExtensionLaunchTests`, three extensions with one background held for 6 s all heard `onStartup`; with one update rolling back, the other two were running 0.13 s after the start. Three cases still load late. The old version after a rollback hears "update" from the failed version. A trial queued behind another hears "update" but no `onStartup`. An extension turned off and on hears "install", and Chorus adds no shim for it. Bitwarden shows its welcome page only once, behind a flag in its storage, so a repeated "install" does no visible harm there; other extensions may differ. A rollback is a second change of version, and anything the new version rewrote in its storage before it failed stays rewritten for the old one.

**Grants during a trial.** The running context during a trial is the new version. Grant changes it reports are held until the trial ends: they replace the record's grants if the update lands, and are dropped if it rolls back or stops, so the old version keeps the grants it had.

**An extension loaded while pages are open.** WebKit tells a context about each tab that opens after it loads. One loaded later, through Get, Add from file or turning it on, knows the pages already open only when WebKit fills them in, which on macOS 27.2 it does only while a page is on screen. Otherwise its content scripts still run in those pages, but their messages fail with "Tab not found" until Chorus restarts, a reload included. Right after a context loads, the host now tells it about any open page WebKit left out, so the extension gets `tabs.onCreated` for each and `tabs.onActivated` for the one on screen, which Chrome does not send. macOS 15 and 26 drop those events while the background is still starting, and macOS 27.2 queues them (CI, 2026-11-16); either way the content scripts reach the background after a reload. `WebExtensionOpenPageTests` pins both cases.

**A copy added by hand.** A record with no catalog id whose whole name, trimmed and case ignored, matches an entry's name or one in its `alsoNamed` list counts as a copy of that entry. Its row shows Added and "You added your own copy, so Chorus won't update it." Get refuses before it downloads, after the download, and at the confirm sheet. The copy keeps no catalog id and never updates, and no saved record changes. A record's name is WebKit's display name, which follows the extension's own translations. So `alsoNamed` holds every name the tested build gives itself, in any of its `_locales`, read with the script below. It can't know the names of other versions, of a copy from another store, or of a later release Get installs. A catalog name the build never uses still matches: Read Aloud's builds call themselves "Read Aloud: A Text to Speech Voice Reader" and its translations, so an unrelated extension named plain "Read Aloud" would count as the catalog's copy. Nico chose on 2026-11-16 to keep this. A copy added with a Mac app often goes by the short name, as Bitwarden's does. Adding from a file next to the catalog's copy is still allowed.

**Reading the names from the builds.** `scripts/catalog_extension_names.py` downloads each entry's `testedVersion` from its source, checks its sha256 as the app does, and reads the manifest's `name` the way WebKit does, for the default locale and every folder in `_locales`. It prints the names that differ from the catalog name, ready to paste into `alsoNamed`, and says on stderr whether the build uses the catalog name at all. Run it with `python3 -I`. It reads each archive without unpacking it, in a new temporary folder that it deletes unless the run fails or `--keep` is given; `--dir` names an empty folder outside the repo instead. Each entry's `namesReadFrom` records the version the names came from, and `testNamesWereReadFromTheTestedVersion` fails when it differs from `testedVersion`, so a version bump needs a new run. `--check` exits 0 when `alsoNamed` matches the builds, 1 when it differs, and 2 when a download or a build can't be read. `--self-test` runs its checks offline.

A toggle, "Update extensions automatically", on by default. With it off, the row shows "Update available" and a button.

**What the checks prove.** The sha256 comes from the same publisher as the file (GitHub computes it at upload; AMO reports its own), so it proves the download arrived whole and unchanged, not who made it. A publisher whose account is taken over can ship a bad version with a matching checksum. Chorus does not check Mozilla's signature on an `.xpi`. The real line of defence is step 2's permission comparison: an update that asks for more waits for the user.

**Limits.** A download over 100 MB is refused, before fetching when the publisher reports the size. An archive that says it unpacks to more than 500 MB is refused before `ditto` runs; this also covers "Add from file". A version must be one to six dot-separated whole numbers, so a tag like `2.1.0-rc1` that the publisher forgot to mark as a prerelease is skipped, and the tag must equal the manifest's `version` or the import is undone. GitHub lists releases by date, so the fetcher takes the highest version on the first page of 100, and skips a release with more than one asset matching the pattern.

**Privacy.** The checks reveal to GitHub and Mozilla which catalog extensions someone uses, the same as any browser's updater. Send no identifier and a plain user agent. GitHub allows 60 unauthenticated calls an hour, far more than a daily check needs.

## Sources, checked end to end 2026-11-13

Each went through `WebExtensionFetcher` against the live servers: latest release, download, size, sha256, manifest version, import. All passed.

| Extension | Source | Version |
|---|---|---|
| Bitwarden | github `bitwarden/clients`, `dist-chrome-*.zip`, prefix `browser-v` | 2026.10.2 |
| uBlock Origin Lite | github `uBlockOrigin/uBOL-home`, `uBOLite_*.chromium.zip` | 2026.1110.1816 |
| Consent-O-Matic | github `cavi-au/Consent-O-Matic`, `consent-o-matic-v*-unpacked-release-chromium.zip` | 1.1.5 |
| Obsidian Web Clipper | github `obsidianmd/obsidian-clipper`, `obsidian-web-clipper-*-chrome.zip` | 1.7.1 |
| SponsorBlock | github `ajayyy/SponsorBlock`, `ChromeExtension.zip` | 6.1.7 |
| DeArrow | github `ajayyy/DeArrow`, `ChromeExtension.zip` | 2.3.10 |
| Return YouTube Dislike | github `Anarios/return-youtube-dislike`, `return-youtube-dislike-chrome-*.zip` | 4.1.7 |
| Simple Translate | amo `simple-translate` | 3.1.0 |
| To DeepL | amo `to-deepl` | 0.9.3 |
| Read Aloud | amo `read-aloud` | 1.84.1 |
| Proton Pass | amo `proton-pass` | 1.43.1 |
| Raindrop.io | amo `raindropio` | 6.6.91 |

## Survey, 2026-11-13

Each package was imported through the real library and loaded by a throwaway engine test (kept in `.remember/tmp/extension-survey/`, not committed) with every permission it asks for, then shown a Wikipedia page for 8 s. "Errors" are what `WKWebExtensionContext.errors` collected, which includes uncaught errors in the background. Users are Firefox daily users from AMO, the only public count; Chrome counts are larger.

| Extension | Package tested | Licence | Firefox users | Result |
|---|---|---|---|---|
| Bitwarden | GitHub Chrome zip | GPL-3.0 | 1,044,031 | Works; fills and copies, checked by hand |
| SponsorBlock | GitHub Chrome zip | LGPL-3.0 | 824,045 | Works, checked by hand |
| Dark Reader | GitHub Chrome MV3 zip | MIT | 1,359,539 | Darkened the page; no errors |
| Return YouTube Dislike | GitHub Chrome zip | GPL-3.0 | 883,929 | No errors |
| uBlock Origin Lite | GitHub Chromium and Safari zips | GPL-3.0 | 22,311 | Blocks requests and hides elements, checked by hand (see below) |
| Consent-O-Matic | GitHub Chromium zip | MIT | 136,299 | No errors |
| Obsidian Web Clipper | GitHub Chrome zip | MIT | 68,656 | No errors |
| Simple Translate | AMO | MPL-2.0 | 249,839 | No errors |
| To DeepL | AMO | MIT | 12,312 | No errors |
| Read Aloud | AMO | GPL-3.0 | 230,453 | Speaks, checked by hand (see below) |
| DeArrow | GitHub Chrome zip | LGPL-3.0 | 34,530 | Works; one harmless error from messaging SponsorBlock |
| Raindrop.io | AMO | MPL-2.0 | 43,774 | Loads; WebKit rejects a keyboard command in its manifest |
| Proton Pass | AMO | GPL-3.0 | 197,273 | Starts since Chorus added `runtime.onUpdateAvailable` (2026-11-14); its popup reached sign-in in a test host once Chorus kept the API globals (2026-11-16); filling not tried |
| Violentmonkey | AMO | MIT | 207,380 | Background stops: no `notifications.onClicked` |
| LanguageTool | AMO | proprietary | 316,419 | Background fails to parse in JavaScriptCore (`¶` at line 26); no `storage.managed` |
| Grammarly | AMO | proprietary | 527,807 | Background errors and asks to talk to its Mac app |

Both open checks passed in a Debug build on 2026-11-15, after a run in a test host. For uBlock Origin Lite, a page served from 127.0.0.1 fetched `c.wired.com`, a tracker in its default `easyprivacy` list that this Mac's network filter lets through, and `example.org` as a control. Without uBOL both loaded, with Chorus's own blocklist on. Seconds after Get, the tracker failed and the control still loaded, with no reload. In its default Optimal mode uBOL hides elements only on sites its lists name, so the page's ad elements stayed. In Complete mode, after a reload, it hid `#AD_300`, `.advertembed` and an `<ad-slot>` element, and the control element stayed. A test host could not show the hiding: uBOL applies it from `requestAnimationFrame`, and WebKit runs none for a page that is not on screen. Read Aloud's Firefox build has no `tts` permission. It speaks with `speechSynthesis` in its background page, in an offline system voice (Samantha on this Mac), and falls back to Google Translate voices played as audio. On the same page, pressing its button made Core Audio report the Chorus process playing sound for about 8 s; nothing else that was playing changed. The probes and the page are in `.remember/tmp/extension-probes/`, not committed.

**Ruled out:**

- uBlock Origin, Privacy Badger, ClearURLs, Ghostery, DuckDuckGo, I Still Don't Care About Cookies: they block through `webRequestBlocking`, which WebKit does not have. uBlock Origin Lite and Chorus's own blocklist cover the same need.
- 1Password, KeePassXC: they need native messaging to their Mac app, which Chorus cannot pass on.
- Tampermonkey, Violentmonkey: user scripts overlap Custom JavaScript, which every service already has.
- Refined GitHub: publishes no release build ("for local testing only").
- Simplify Gmail: not on AMO; Chrome Web Store only.

## First catalog

Tested clean, in order of how useful they are in Chorus:

1. Bitwarden (passwords)
2. uBlock Origin Lite (blocking and cosmetic filtering, beyond Chorus's own list)
3. Consent-O-Matic (answers cookie banners)
4. Simple Translate and To DeepL (translate a message in Slack, WhatsApp or Gmail)
5. Obsidian Web Clipper (save a page or message to a vault)
6. SponsorBlock, DeArrow, Return YouTube Dislike (for people who keep YouTube in Chorus)
7. Read Aloud

Add after a fix in `ExtensionCompatibility`, which already has the pattern: Proton Pass (stub `runtime.onUpdateAvailable`), Raindrop.io (check the bookmark button works despite the manifest warning). Violentmonkey stays out, and so does its `notifications.onClicked` stub (Nico, 2026-11-13).

Leave out Dark Reader: Chorus already offers Dark Reader per service, and two copies would fight.

## Decided with Nico, 2026-11-13

- The first catalog is the list above. The YouTube helpers stay in, listed last under their own category.
- uBlock Origin Lite comes from its Chrome build (`uBOLite_*.chromium.zip`), not the Safari one.
- "Update extensions automatically" is on by default. An update that asks for more still waits for the user's OK.
- The catalog gets a "Suggest an extension" link to a GitHub issue form that asks for the extension's name and its source.
- No Violentmonkey and no `notifications.onClicked` stub.

## Decided with Nico, 2026-11-16

- A catalog name the build never uses still matches a copy added by hand (see "A copy added by hand"). A clash hides one Get button and changes no saved record.

## Build order

1. Done on `feat/extension-catalog`: `WebExtensionSource` (github, amo), `WebExtensionFetcher` (latest release; download plus verify plus import), with recorded API answers and no network in the tests.
2. Done on `feat/extension-catalog`: record fields, the staged swap at load, rollback, the permission comparison, and `testDataSurvivesAVersionSwap`. `ExtensionManager` applies a ready update when it starts an extension.
3. Done on `feat/extension-catalog` (`7ad2ef4`): the catalog JSON, a "Get Extensions" section in Settings, the update toggle, "Update needs your OK", the "Suggest an Extension" link and its issue form. `ExtensionCatalogController` runs the check after `startEnabled` and every 24 hours; staging never runs while a start for the record is in progress, and re-checks `wantsUpdate(to:)` on the current record after every await.
4. Done on `feat/extension-catalog`: `ExtensionCompatibility` adds `runtime.onUpdateAvailable`, and Proton Pass 1.43.1 now loads with no errors. On 2026-11-16 its popup still said "Your browser is having difficulties activating Proton Pass". Its background and popup replace the global `chrome` and `browser` with Proxies just after they start. WebKit finds the page to hand an event to through those two globals (`enumerateFramesAndNamespaceObjects`), so the background never heard the popup. The compatibility script now keeps both names on WebKit's object in extension worlds and ignores writes to them (`WebExtensionHiddenAPITests`). With its popup working, Proton Pass's page script then failed on `requestIdleCallback`, which WKWebView leaves off; it waits on it before it looks for login forms. The compatibility script adds a stand-in in extension worlds (`WebExtensionIdleCallbackTests`), and Proton Pass then logged no errors in a Debug build.
5. Done by hand on 2026-11-14 in a Debug build, with Consent-O-Matic, driven through Accessibility:
   - Install: Get downloaded 1.1.5 from GitHub, the confirm sheet named the version and the publisher, and the record saved `catalogID` and `installedVersion`.
   - Update: the record was pointed at the real 1.1.3 files. The launch check staged 1.1.5 ("installs when Chorus restarts"), the next launch swapped it in ("Updated to version 1.1.5"), and a setting changed under 1.1.3 still read as changed in 1.1.5 after that launch and after one more. Consent-O-Matic did not reopen its first-run page, which it shows only when its storage is empty.
   - Refused update: with `tabs` taken out of the grants, 1.1.5 staged as "needs your OK", the review sheet listed the one new ask, and Skip This Version saved `skippedVersion` and deleted the staged folder.
   - Rollback: a staged 1.1.5 whose worker throws rolled back, and the row said so. This pass found that the old version then ran with no background for the rest of that session; fixed in `27c219a` (see "After a rollback the old version waits 12 s").
   - Remove deleted the record, its folder and its stored data.
   Step 6 covers what this pass left.
6. Checked by hand on 2026-11-15 in a Debug build, driven through Accessibility. With automatic updates off, the row showed "Version 1.1.5 is available" and Update; Update staged it, and the next launch swapped it in. With `tabs` taken out of the grants, Allow Update in the review sheet saved the OK, and the next launch installed 1.1.5 with `tabs` granted. With the list's folder read-only, Get showed "Chorus couldn't save its list of extensions, so it didn't add Proton Pass" and left the list and Packages as they were. The Bitwarden row showed Added and its caption, and the hand-added Bitwarden record did not change. uBlock Origin Lite's blocking and Read Aloud's speech are under the survey above. Proton Pass filling and Raindrop's bookmark button need real accounts and were not tried.
7. Checked by hand on 2026-11-16 in a Debug build with Consent-O-Matic and its 1.1.3 files, driven through Accessibility. With `tabs` taken out of the grants and the Extensions folder read-only, Allow Update in the review sheet showed "Chorus couldn't update Consent-O-Matic" and "Chorus couldn't save its list of extensions, so nothing changed." The list stayed byte for byte the same and the update still waited for an OK. With automatic updates off and the folder read-only, Update showed the same alert, the list did not change, and the downloaded copy was deleted. Proton Pass's popup reached its sign-in screen once step 4's two fixes were in, and Raindrop's did with only its known manifest warning; neither was signed in to. With the parallel start, four extensions reached WebKit 1.1 to 1.4 s after the controller was made, on each of three launches; one at a time, the last had finished at 2.4 s. Every extension added for these checks was removed, and Bitwarden's record was left as it was.
