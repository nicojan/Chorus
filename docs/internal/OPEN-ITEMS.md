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

## Camera/microphone trust boundary: both cases handled

Fixed: the capture check now uses
`WebViewCoordinator.captureOriginBelongsToService`, which treats a curated set of
multi-tenant hosting suffixes (`github.io`, `web.app`, `vercel.app`, and more) as
public suffixes. Two owners on the same shared suffix no longer count as one site,
so a service pinned to Allow can no longer hand its grant to another site there.
Same registrable domain still matches, so `*.slack.com` workspaces keep working. A
test covers it.

Cross-domain calls: trust is anchored to a service's home host, so a call service
whose live capture host differs by registrable domain would be denied. Two things
now handle this. First, a `firstParty` flag on six curated catalog entries
(Messenger, Facebook, WhatsApp, Teams, Google Meet, Google Chat). For a flagged
service pinned to Allow, a capture request from its own main frame is granted even
on a foreign domain, the way the vendor's native app behaves. The accepted risk is
bounded: user-clicked foreign links already open in the browser, a subframe never
qualifies, the service must be pinned to Allow, and the flag drops the moment the
user edits the service URL off the vendor's site. Second, a vendor still on Ask,
and every service without the flag, gets a per-origin prompt that names the real
origin ("Allow messenger.com to use your microphone?") and isn't saved. Confirm by
hand: on a flagged vendor pinned to Allow the call should just work; on Ask it
should prompt naming the real origin rather than failing silently.

WhatsApp is single-host, so the flag never fires for it today. It is kept because
it was named as a service to trust and because an inert flag costs nothing.

Rejected: a per-service capture-host allowlist, a maintained list of trusted hosts
per catalog entry. The first-party flag covers the same cases with a boolean
instead of a hand-kept, security-sensitive host list that mis-trusts if it goes
stale. A full Public Suffix List would still generalise the suffix handling.

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
