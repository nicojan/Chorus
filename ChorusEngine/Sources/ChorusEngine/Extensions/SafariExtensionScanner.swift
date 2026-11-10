import Foundation

/// Finds the Safari web extensions installed with Mac apps. The system's own
/// lookup (PlugInKit) refuses to list them to any app but Safari, so this reads
/// the app bundles directly: each `.app` in the Applications folders, and the
/// `.appex` files in its PlugIns folder whose extension point is Safari's.
public enum SafariExtensionScanner {
    public struct Found: Sendable, Equatable, Identifiable {
        public var id: String { path }
        /// The `.appex` path, as `WebExtensionRecord.Source.appExtension` stores it.
        public let path: String
        public let bundleIdentifier: String
        /// The extension's own name from its Info.plist.
        public let name: String
        /// The app it came with.
        public let appName: String
        public let appPath: String
    }

    static let extensionPoint = "com.apple.Safari.web-extension"

    /// `/Applications` and `~/Applications`, each one folder deep as well, so
    /// apps kept in a subfolder (Utilities, Setapp) are found.
    public static var defaultSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    public static func scan(in directories: [URL] = defaultSearchDirectories) -> [Found] {
        let apps = directories.flatMap { appBundles(in: $0, depth: 1) }
        let found = apps.flatMap(safariExtensions(in:))
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.bundleIdentifier).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func appBundles(in directory: URL, depth: Int) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.flatMap { child -> [URL] in
            if child.pathExtension == "app" { return [child] }
            let isFolder = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isFolder && depth > 0 ? appBundles(in: child, depth: depth - 1) : []
        }
    }

    static func safariExtensions(in app: URL) -> [Found] {
        let plugins = app.appending(path: "Contents/PlugIns", directoryHint: .isDirectory)
        let appexes = ((try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "appex" }
        let appName = displayName(ofBundleAt: app) ?? app.deletingPathExtension().lastPathComponent
        return appexes.compactMap { appex in
            guard let info = infoPlist(ofBundleAt: appex),
                  let ext = info["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == extensionPoint,
                  let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? appex.deletingPathExtension().lastPathComponent
            return Found(path: appex.path, bundleIdentifier: bundleID, name: name, appName: appName, appPath: app.path)
        }
    }

    private static func infoPlist(ofBundleAt url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func displayName(ofBundleAt url: URL) -> String? {
        guard let info = infoPlist(ofBundleAt: url) else { return nil }
        return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
    }
}
