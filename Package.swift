// swift-tools-version: 6.0
// 6.0 on purpose: CI's macOS 14 job builds with Xcode 16.2, which reads
// nothing newer.
import PackageDescription

// ChorusEngine is Chorus's WebKit layer, shared with other apps. Chorus builds
// it as a local package (see project.yml); another app depends on this repo by
// URL and pins a release tag with `exact:`. See docs/internal/ENGINE.md.
let package = Package(
    name: "ChorusEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChorusEngine", targets: ["ChorusEngine"]),
    ],
    targets: [
        .target(
            name: "ChorusEngine",
            path: "ChorusEngine/Sources/ChorusEngine"
        ),
    ]
)
