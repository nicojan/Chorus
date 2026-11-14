import Foundation

/// The extensions the user added, kept on disk outside SwiftData: a JSON list
/// of records and a Packages folder holding the extensions copied in from a
/// folder or an archive. Keeping it out of the model means adding extensions
/// needs no schema version and cannot touch the store.
///
/// Every write replaces the file whole, through a temporary file, so a crash
/// mid-write leaves the old list.
public struct WebExtensionLibrary: Sendable {
    public enum ImportError: LocalizedError, Equatable {
        case notFound
        case noManifest
        case unreadableManifest
        case unsupportedArchive
        case extractionFailed(String)
        case containsLinks

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "Chorus can't find that file."
            case .noManifest:
                return "That isn't a web extension. Chorus looks for a manifest.json file at the top of the folder or archive."
            case .unreadableManifest:
                return "The extension's manifest.json can't be read."
            case .unsupportedArchive:
                return "Chorus can open a folder, a .zip, a .crx or an .xpi file."
            case .extractionFailed(let detail):
                return "Chorus couldn't unpack the archive. \(detail)"
            case .containsLinks:
                return "The extension contains links to files outside it, which Chorus doesn't allow."
            }
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var recordsFile: URL { directory.appending(path: "extensions.json") }
    var packagesDirectory: URL { directory.appending(path: "Packages", directoryHint: .isDirectory) }

    // MARK: - Records

    /// The saved records, or none when there is no file yet. A file that will
    /// not decode is moved aside rather than overwritten by the next save, so a
    /// newer format or a damaged file can still be looked at.
    public func loadRecords() -> [WebExtensionRecord] {
        guard let data = try? Data(contentsOf: recordsFile) else { return [] }
        do {
            return try JSONDecoder.library.decode([WebExtensionRecord].self, from: data)
        } catch {
            let aside = directory.appending(path: "extensions.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: recordsFile, to: aside)
            AppLogger.extensions.error("Extension list unreadable, moved aside: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func saveRecords(_ records: [WebExtensionRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.library.encode(records)
        try data.write(to: recordsFile, options: .atomic)
    }

    // MARK: - Packages

    /// Where a copied-in extension's files are. A directory URL, which
    /// `WKWebExtension(resourceBaseURL:)` requires.
    public func packageURL(folder: String) -> URL {
        packagesDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    /// Copies an extension into the library and returns its folder name. Takes
    /// a folder, or a .zip, .crx or .xpi archive, and accepts a manifest at the
    /// top or one folder down, which is how most release zips are laid out.
    public func importPackage(from source: URL) throws -> String {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw ImportError.notFound }

        let staging = fm.temporaryDirectory.appending(path: "chorus-extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }

        let unpacked: URL
        if isDirectory.boolValue {
            unpacked = source
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            unpacked = staging.appending(path: "contents", directoryHint: .isDirectory)
            try Self.extractArchive(source, into: unpacked, scratch: staging)
        }

        guard let root = Self.manifestRoot(in: unpacked) else { throw ImportError.noManifest }
        guard Self.readManifest(at: root) != nil else { throw ImportError.unreadableManifest }
        // A symbolic link in a package could point an extension page at any
        // file on the Mac, such as ~/.ssh. Extensions never need one.
        guard !Self.containsLinksOrEscapes(root) else { throw ImportError.containsLinks }

        let folder = UUID().uuidString
        try fm.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: root, to: packageURL(folder: folder))
        return folder
    }

    /// Deletes package folders no record names. Does nothing while an
    /// unreadable list sits in the folder: its records may name them.
    public func removeUnusedPackages(keeping folders: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard !names.contains(where: { $0.hasPrefix("extensions.unreadable-") }) else { return }
        let present = (try? FileManager.default.contentsOfDirectory(atPath: packagesDirectory.path)) ?? []
        for name in present where !folders.contains(name) {
            removePackage(folder: name)
        }
    }

    public func removePackage(folder: String) {
        // A folder name is always a UUID this library made; refuse anything
        // else so a damaged record cannot point a delete outside Packages.
        guard UUID(uuidString: folder) != nil else { return }
        try? FileManager.default.removeItem(at: packageURL(folder: folder))
    }

    // MARK: - Helpers

    /// The folder holding manifest.json: `directory` itself, or its only
    /// subfolder (ignoring macOS's `__MACOSX` and hidden files).
    static func manifestRoot(in directory: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appending(path: "manifest.json").path) { return directory }
        let children = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let folders = children.filter {
            $0.lastPathComponent != "__MACOSX"
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard folders.count == 1, let only = folders.first,
              fm.fileExists(atPath: only.appending(path: "manifest.json").path) else { return nil }
        return only
    }

    /// Whether anything under `root` is a symbolic link, or resolves outside
    /// `root` (a `../` entry an archive tool let through).
    static func containsLinksOrEscapes(_ root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return true }
        for case let item as URL in walker {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return true }
            let path = item.resolvingSymlinksInPath().standardizedFileURL.path
            if !(path == base || path.hasPrefix(base + "/")) { return true }
        }
        return false
    }

    /// The manifest as a dictionary with a manifest_version, or nil.
    static func readManifest(at root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appending(path: "manifest.json")) else { return nil }
        // Chrome tolerates a byte order mark; JSONSerialization does not.
        let trimmed = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed)) as? [String: Any],
              object["manifest_version"] != nil else { return nil }
        return object
    }

    private static func extractArchive(_ archive: URL, into destination: URL, scratch: URL) throws {
        let ext = archive.pathExtension.lowercased()
        let zip: URL
        switch ext {
        case "zip", "xpi":
            zip = archive
        case "crx":
            guard let data = try? Data(contentsOf: archive), let payload = zipPayload(ofCRX: data) else {
                throw ImportError.extractionFailed("The .crx file is damaged or uses an unknown format.")
            }
            zip = scratch.appending(path: "payload.zip")
            try payload.write(to: zip)
        default:
            throw ImportError.unsupportedArchive
        }
        try runDitto(zip: zip, destination: destination)
    }

    private static func runDitto(zip: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ImportError.extractionFailed(error.localizedDescription)
        }
        // Read to the end before waiting: a full pipe would otherwise stop
        // ditto mid-write while this waits for it to exit.
        let errorOutput = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorOutput, encoding: .utf8) ?? ""
            throw ImportError.extractionFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The zip inside a Chrome .crx: a "Cr24" header, a version, then either a
    /// public key and signature (version 2) or one protobuf header (version 3),
    /// then a plain zip. Nil for anything else.
    static func zipPayload(ofCRX data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 16, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] else { return nil }
        func uint32(at offset: Int) -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        guard let version = uint32(at: 4) else { return nil }
        let start: Int
        switch version {
        case 2:
            guard let keyLength = uint32(at: 8), let signatureLength = uint32(at: 12) else { return nil }
            start = 16 + keyLength + signatureLength
        case 3:
            guard let headerLength = uint32(at: 8) else { return nil }
            start = 12 + headerLength
        default:
            return nil
        }
        // A zip starts with a local file header, "PK\u{3}\u{4}".
        guard start + 4 <= bytes.count, bytes[start..<start + 4] == [0x50, 0x4B, 0x03, 0x04] else { return nil }
        return Data(bytes[start...])
    }
}

private extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
