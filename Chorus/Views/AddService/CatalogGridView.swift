import SwiftUI
import SwiftData

/// The catalog's tiles. It only reports which entry was picked: where the
/// service goes, and whose sign-in it uses, are the Add Service sheet's to
/// decide (see `ServiceAdding`).
struct CatalogGridView: View {
    let searchText: String
    let onPick: (ServiceCatalogEntry) -> Void

    private let catalog = ServiceCatalog.shared
    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 12)
    ]

    private var filteredEntries: [ServiceCatalogEntry] {
        if searchText.isEmpty { return catalog.entries }
        let query = searchText.lowercased()
        return catalog.entries.filter {
            $0.name.lowercased().contains(query) ||
            $0.category.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    private var groupedEntries: [(String, [ServiceCatalogEntry])] {
        let grouped = Dictionary(grouping: filteredEntries, by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(groupedEntries, id: \.0) { category, entries in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(entries) { entry in
                                CatalogEntryButton(entry: entry) {
                                    onPick(entry)
                                }
                            }
                        }
                    }
                }

                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search term or add a custom URL")
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

private struct CatalogEntryButton: View {
    let entry: ServiceCatalogEntry
    let action: () -> Void

    @State private var isHovering = false
    @State private var icon: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                iconView
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.control))

                Text(entry.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: ChorusRadius.control)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.description)
        .accessibilityLabel("Add \(entry.name)")
        .task {
            // Fetch the bytes, not the image. NSImage is not Sendable in the
            // Xcode 16 SDK, so returning one from the actor is an error there.
            // The actor still caches the bytes in memory, so this only touches
            // disk the first time; the decode is what moved to this side.
            icon = await CatalogIconCache.shared.iconData(for: entry.id).flatMap(NSImage.init(data:))
        }
    }

    /// The bundled brand mark (`brand-<id>`), the same one the rail draws once
    /// the service is added. Checked before the fetched favicon because some
    /// favicons are not the logo: Figma's file browser serves a teal loading
    /// glyph.
    private var brandAssetName: String? {
        let name = "brand-\(entry.id)"
        return NSImage(named: name) != nil ? name : nil
    }

    @ViewBuilder
    private var iconView: some View {
        if let brand = brandAssetName {
            Image(brand)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
        } else if let icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text(String(entry.name.prefix(1)))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: ChorusRadius.control)
                        .fill(colorForCategory(entry.category))
                )
        }
    }

    private func colorForCategory(_ category: String) -> Color {
        switch category.lowercased() {
        case "email": return .blue
        case "messaging": return .purple
        case "social": return .pink
        case "productivity": return .green
        case "ai": return .orange
        default: return .gray
        }
    }
}
