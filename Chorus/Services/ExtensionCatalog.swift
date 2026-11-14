import ChorusEngine
import Foundation

/// The groups Settings shows the catalog in. Case order is display order.
enum ExtensionCatalogCategory: String, Codable, CaseIterable, Sendable {
    case passwords, privacy, translation, reading, youtube

    var title: String {
        switch self {
        case .passwords: return "Passwords"
        case .privacy: return "Privacy"
        case .translation: return "Translation"
        case .reading: return "Reading and Saving"
        case .youtube: return "YouTube"
        }
    }
}

/// One extension Chorus offers to get, checked to work in Chorus.
struct ExtensionCatalogEntry: Codable, Identifiable, Sendable, Equatable {
    /// Permanent: saved as `WebExtensionRecord.catalogID`. Never renamed or
    /// reused, or installed copies stop updating or update to the wrong thing.
    let id: String
    let name: String
    /// One line.
    let summary: String
    let category: ExtensionCatalogCategory
    /// An SPDX identifier.
    let licence: String
    let source: WebExtensionSource
    /// The version we tried. Review data the tests pin; Get installs the
    /// latest release, and the UI does not show this.
    let testedVersion: String
    /// One sentence on what does not work in Chorus, shown on the row and in
    /// the confirm sheet.
    let knownGaps: String?

    /// Where the download comes from, in words.
    var publisherLine: String {
        switch source {
        case .github(let owner, let repo, _, _): return "From \(owner)/\(repo) on GitHub"
        case .amo: return "From addons.mozilla.org"
        }
    }
}

/// The extensions bundled in `ExtensionCatalog.json`.
struct ExtensionCatalog: Sendable {
    /// In file order.
    let entries: [ExtensionCatalogEntry]

    static let bundled: ExtensionCatalog = load(from: .main)

    init(entries: [ExtensionCatalogEntry]) {
        self.entries = entries
    }

    /// The catalog in `bundle`, or an empty one when the file is missing.
    static func load(from bundle: Bundle) -> ExtensionCatalog {
        guard let url = bundle.url(forResource: "ExtensionCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            AppLogger.extensions.error("ExtensionCatalog.json is missing from the bundle")
            return ExtensionCatalog(entries: [])
        }
        return decode(data)
    }

    /// Decodes lossily: a broken entry drops out and the rest still load.
    static func decode(_ data: Data) -> ExtensionCatalog {
        do {
            let decoded = try JSONDecoder().decode([FailableDecodable<ExtensionCatalogEntry>].self, from: data)
            let entries = decoded.compactMap(\.value)
            let dropped = decoded.count - entries.count
            if dropped > 0 {
                AppLogger.extensions.error("Skipped \(dropped, privacy: .public) unreadable extension catalog entries")
            }
            return ExtensionCatalog(entries: entries)
        } catch {
            AppLogger.extensions.error("Could not read ExtensionCatalog.json: \(error.localizedDescription, privacy: .public)")
            return ExtensionCatalog(entries: [])
        }
    }

    func entry(id: String) -> ExtensionCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// The entries by category, in `CaseIterable` order, file order within
    /// each. Categories with no entries are left out.
    var sections: [(category: ExtensionCatalogCategory, entries: [ExtensionCatalogEntry])] {
        ExtensionCatalogCategory.allCases.compactMap { category in
            let inCategory = entries.filter { $0.category == category }
            return inCategory.isEmpty ? nil : (category, inCategory)
        }
    }
}
