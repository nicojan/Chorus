# Contributing to Chorus

Thanks for taking an interest in Chorus. Bug reports, fixes, and new features
are all welcome.

## Build and test

You will need macOS 14 or later, Xcode 15 or newer, and XcodeGen
(`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'
```

You can also open `Chorus.xcodeproj` in Xcode and run the Chorus scheme.

## Making a change

- Add a test for any logic you can exercise on its own. The tests in
  `ChorusTests/` cover pure logic such as badge parsing, input validation, and
  reordering.
- Match the surrounding style: small files, immutable data, clear names.
- A new `AppPreferences` field should be `Optional` with a nil-means-default
  accessor. Chorus ships to people who already have saved data, and that pattern
  lets SwiftData migrate an old store in place instead of wiping it. Copy the
  shape of a field that is already there.
- The Xcode project comes from `project.yml`. Change a version or a build
  setting in both `project.yml` and the `.pbxproj`, or the next
  `xcodegen generate` will undo it.
- Run the test suite before you open a pull request.

## Pull requests

- Branch off `main` and keep each pull request to a single change.
- If two pull requests touch the same type or view, they can each look clean
  against `main` and still collide once the first one lands. Say so in the
  description when your change edits `AppPreferences` or a settings view.
- Write commit messages as `type: summary`, for example `fix: ...` or
  `feat: ...`, with a short body that says why.
- Say what you changed and how you checked it.

## Writing

Anything a user or the public reads, such as the README, release notes, or these
docs, should be plain and direct. `CLAUDE.md` has the full standard.
