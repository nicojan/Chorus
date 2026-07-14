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

## Camera/microphone trust boundary: one case fixed, one open

Fixed: the capture check now uses
`WebViewCoordinator.captureOriginBelongsToService`, which treats a curated set of
multi-tenant hosting suffixes (`github.io`, `web.app`, `vercel.app`, and more) as
public suffixes. Two owners on the same shared suffix no longer count as one site,
so a service pinned to Allow can no longer hand its grant to another site there.
Same registrable domain still matches, so `*.slack.com` workspaces keep working. A
test covers it.

Open: trust is still anchored to a service's home host, so a call service whose
live capture host differs by registrable domain is denied. It fails safe, but the
call breaks. Messenger (`facebook.com` then `messenger.com`) and Teams
(`*.cloud.microsoft`) are the likely cases. Closing this needs data: for each call
service, note the host it actually calls `getUserMedia` from (the
`Media capture denied: request origin ...` line in the Console names it), then add
a per-service allowlist of its capture hosts, with a catalog field as the natural
home. The curated suffix list above is also not the full Public Suffix List;
adopting a real one would generalise the fix.

## Close the test gaps

Unit tests cover the policy resolver, the asked-field gating, and the capture
origin-trust check. Still untested: the prompt-queue rules (answer-by-id, drain on
delete or teardown), `muteAllMicrophones` target selection, and the `captureKind`
mapping. Pulling a couple more pure helpers out would make them reachable.

## Try the rest by hand

Not yet exercised: the ⇧⌘M "Mute All Microphones" command (the mic dot should turn
orange and the far end should see you muted) and a per-service Camera or Microphone
set to Deny.

Build and test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`.
Background lives in the camera-mic-permissions and review-backlog memories.
