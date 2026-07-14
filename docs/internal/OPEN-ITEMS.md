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

Open: trust is anchored to a service's home host, so a call service whose live
capture host differs by registrable domain is denied. It fails safe, but the call
breaks. Messenger (`facebook.com` then `messenger.com`) and Teams
(`*.cloud.microsoft`) are the likely cases, still unverified.

The mechanism to build once it's confirmed is a per-origin prompt. A static
allowlist is the weaker alternative. When a capture request comes from the
service's own web view on a host that is not the service's origin, and it comes
from the main frame rather than a third-party subframe, show a prompt that names
the real origin ("Allow messenger.com to use your microphone?") instead of
denying. A service set to Deny still denies, and a matching Allow is never
extended silently to the foreign origin, so the shared-suffix protection holds.
Don't persist the foreign-origin answer; our policy store is keyed per service, so
there is nowhere to record a per-origin choice, and we ask again as needed, the
way a browser does. This needs no per-service data and no host list to maintain.
First confirm a Teams, Messenger, or WhatsApp call actually hits this path (the
`Media capture denied: request origin ...` line names the host). A full Public
Suffix List would still generalise the suffix handling above.

## Humanizer-check the in-app strings

The public-writing rules now cover in-app strings and error messages (main commit
`7f55ab8`). Before shipping, run the media feature's user-facing text through the
humanizer check and Orwell's rules. Cover:

- the permission alert title and message in `ContentView`;
- the Camera and microphone labels and help in the Edit sheet and Privacy settings;
- any capture message a user can see.

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
