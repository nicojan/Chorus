# Open items

Camera and microphone support is built and committed on
`harden/1.5.3-review-fixes`, tested by hand (Meet: camera, mic, screen share;
Discord: voice). Here is what is left for the next session.

## Cut the 1.5.3 release

The feature is committed but not released. To ship it:

1. Bump the version in both `project.yml` and the `.pbxproj` (`MARKETING_VERSION`
   to `1.5.3`, `CURRENT_PROJECT_VERSION` up one), then run `xcodegen generate`.
2. Write a CHANGELOG and release-notes entry for the feature. Run the text through
   the humanizer check and Orwell's rules first; the repo requires it for anything
   the public reads.
3. Notarize and staple `Chorus.app` (this needs the Developer ID identity on your
   Mac), put it at the repo root, build the DMG, cut the `gh release`, then sign
   and regenerate `docs/appcast.xml`. Steps are in `release/DISTRIBUTION.md`.

## Decide the camera/microphone trust boundary

The same-site check (`WebViewCoordinator.belongsToService` / `effectiveDomain`)
approximates a service's registrable domain from a hardcoded two-part-TLD list.
Because that list is not a full public-suffix list, two linked cases slip through:

- Shared-hosting suffixes (`github.io`, `web.app`, `vercel.app`, `pages.dev`,
  `herokuapp.com`) collapse to one site, so a service pinned to Allow on such a
  suffix could hand its grant to another site on the same suffix.
- Trust is anchored to a service's home host, so a call service whose live capture
  host differs (Messenger `facebook.com` then `messenger.com`, Teams
  `*.cloud.microsoft`) is denied. It fails safe, but the call breaks.

Tightening to an exact-host match closes the first case and worsens the second, so
the fix needs data. For each call service, note the host it actually calls
`getUserMedia` from (the `Media capture denied: request origin ...` line in the
Console names it), then choose between a public-suffix list and an exact-host match
with a per-service allowlist.

## Close the test gaps

Unit tests cover the policy resolver and the asked-field gating. Still untested:
the prompt-queue rules (answer-by-id, drain on delete or teardown), the
cross-origin `isCaptureFrameTrusted` check, `muteAllMicrophones` target selection,
and the `captureKind` mapping. Pulling a couple more pure helpers out would make
them reachable.

## Try the rest by hand

Not yet exercised: the ⇧⌘M "Mute All Microphones" command (the mic dot should turn
orange and the far end should see you muted) and a per-service Camera or Microphone
set to Deny.

Build and test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`.
Background lives in the camera-mic-permissions and review-backlog memories.
