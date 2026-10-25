# Contributing to Chorus

Thanks for taking an interest in Chorus. Bug reports, fixes, and new features
are all welcome.

## Build and test

You will need macOS 14 or later, Xcode 16 or newer, and XcodeGen
(`brew install xcodegen`). Xcode 15 cannot open the project: the file is in the
format Xcode 16 introduced, and older versions refuse it outright rather than
warning you.

```sh
xcodegen generate
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'
```

You can also open `Chorus.xcodeproj` in Xcode and run the Chorus scheme.

CI builds with Xcode 16.2, whose compiler rejects some code that newer Xcode accepts. Five cases so far:

- A private stored property in a View makes its memberwise initialiser private, so another file cannot build the view.
- An overloaded method passed to `contains(where:)` reads as a throwing one. Pass a closure.
- `NSItemProvider`'s `registerDataRepresentation` loader is taken as main-actor bound. Build the provider with `NSItemProvider(item:typeIdentifier:)`.
- A View's static property cannot be read from a `nonisolated` function. Mark the property `nonisolated`.
- A main-actor function passed by name to `forEach` reads as nonisolated and throwing. Call it in a `for` loop.

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
