# Chorus — project instructions

Native macOS app: a WKWebView multi-service browser (a Rambox/Franz alternative),
SwiftUI + SwiftData. Distributed directly — Developer ID-signed, notarized DMG
with Sparkle auto-updates. Not sandboxed, not on the App Store.

## Public-facing writing

Everything a user or the public reads — `README.md`, GitHub release notes, the
appcast and any website copy, `DISTRIBUTION.md`, and every other doc in this
public repo — must meet two standards:

1. **Pass the mcp-humanizer check.** Draft the text, run `humanizer_check_text`
   on it, fix every finding, and re-run until `prohibitions_clear` is true. Then
   self-attest the manual-review items. Reading the rules alone leaves about half
   the problems in place — the check-then-fix loop is what does the work.

2. **Follow George Orwell's six rules** (from *Politics and the English
   Language*):
   1. Never use a metaphor, simile, or other figure of speech you are used to
      seeing in print.
   2. Never use a long word where a short one will do.
   3. If it is possible to cut a word out, always cut it out.
   4. Never use the passive where you can use the active.
   5. Never use a foreign phrase, a scientific word, or a jargon word if you can
      think of an everyday English equivalent.
   6. Break any of these rules sooner than say anything outright barbarous.

Write plain, direct, active, concrete prose. No marketing gloss, no AI tells.

## Build & test

- Test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`
- The project is generated from `project.yml` via XcodeGen. When you change build
  settings (for example a version bump), edit both `project.yml` and the
  `.pbxproj` so a later `xcodegen generate` stays consistent.

## Releasing

See `DISTRIBUTION.md`. In short: the notarized, stapled `Chorus.app` is placed at
the repo root; package a DMG with `hdiutil`, cut a `gh release`, then sign and
regenerate `docs/appcast.xml`.
