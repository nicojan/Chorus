import SwiftUI
import SwiftData

/// The ⌘K switcher. It sits at a fixed spot near the top of the window, as
/// Spotlight does, and only the list below the field changes height. It used
/// to be a sheet, which macOS keeps centred, so every keystroke that changed
/// the number of results moved the field.
struct QuickSwitcherView: View {
    @Environment(AppState.self) private var appState
    @Query private var allLinks: [SpaceServiceLink]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    /// Global services have no links, so the link query never sees them.
    @Query(filter: #Predicate<ServiceInstance> { $0.isGlobal == true })
    private var globalServices: [ServiceInstance]

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var results: [QuickSwitcherResult] = []
    @FocusState private var fieldFocused: Bool
    /// The most rows the window has room for below the field, so a short
    /// window scrolls the list instead of cutting the panel off.
    var maxRows: Int = QuickSwitcherView.maxVisibleRows

    static let width: CGFloat = 420
    /// Every row is this tall, so the list's height follows from its count.
    static let rowHeight: CGFloat = 46
    /// The list scrolls past this many rows.
    static let maxVisibleRows = 8
    private static let listPadding: CGFloat = 8

    /// The list's height for a number of results: one row for "no matches",
    /// otherwise every row up to the cap.
    static func listHeight(forResultCount count: Int, maxRows: Int = maxVisibleRows) -> CGFloat {
        CGFloat(min(max(count, 1), maxRows)) * rowHeight + listPadding
    }

    /// How far below the window's top edge the field sits: about a fifth of
    /// the way down, as Spotlight sits on the screen.
    static func topInset(windowHeight: CGFloat) -> CGFloat {
        max(48, windowHeight * 0.18)
    }

    /// Rows that fit between the field and the bottom of the window.
    static func maxRows(windowHeight: CGFloat) -> Int {
        let fieldAndMargins: CGFloat = 90
        let room = windowHeight - topInset(windowHeight: windowHeight) - fieldAndMargins
        return min(maxVisibleRows, max(3, Int(room / rowHeight)))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
                .frame(height: Self.listHeight(forResultCount: results.count, maxRows: maxRows))
        }
        .frame(width: Self.width)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.surface))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onChange(of: searchText) {
            selectedIndex = 0
            recomputeResults()
        }
        // Key off a content signature, not just the count: a rename (or a moved
        // service) changes the label/membership without changing how many links
        // exist, and the results would otherwise show stale text while open.
        .onChange(of: linksSignature) {
            recomputeResults()
        }
        .onAppear {
            recomputeResults()
            // Focus set during onAppear is dropped while the overlay is still
            // joining the window (the rail kept the keys), so ask again a beat
            // later. A sheet used to do this by itself.
            fieldFocused = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                fieldFocused = true
            }
            FeatureTips.markUsed(.openQuickSwitcher)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func dismiss() {
        appState.showQuickSwitcher = false
    }

    /// A stable string signature of the links' displayed content, so onChange
    /// fires on renames and space moves — not only on insert/delete.
    private var linksSignature: [String] {
        let linked = allLinks
            .compactMap(\.liveEnds)
            .map { "\($0.service.id)|\($0.service.label)|\($0.space.id)|\($0.space.name)" }
        let global = globalServices.map { "\($0.id)|\($0.label)|global|\($0.globalSortOrder ?? -1)" }
        return global + linked
    }

    private func recomputeResults() {
        // In rail order, space by space, so an empty search opens the first
        // service of the first space on Return, not whatever the store returned.
        // Globals lead, as they do in the rail.
        let globalResults = RailItems.liveGlobals(globalServices)
            .map { service in
                QuickSwitcherResult(
                    id: "global-\(service.id)",
                    label: service.label,
                    spaceName: "Global",
                    spaceEmoji: "🌐",
                    serviceID: service.id,
                    spaceID: nil,
                    iconData: service.customIconData ?? service.fetchedIconData
                )
            }
        let linkedResults = allLinks
            .compactMap { link in link.liveEnds.map { (order: link.sortOrder, ends: $0) } }
            .sorted { ($0.ends.space.sortOrder, $0.order) < ($1.ends.space.sortOrder, $1.order) }
            .map(\.ends)
            .map { space, service in
                QuickSwitcherResult(
                    id: "\(space.id)-\(service.id)",
                    label: service.label,
                    spaceName: space.name,
                    spaceEmoji: space.emoji,
                    serviceID: service.id,
                    spaceID: space.id,
                    iconData: service.customIconData ?? service.fetchedIconData
                )
            }
        let serviceResults = globalResults + linkedResults

        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            results = serviceResults
        } else {
            let query = searchText.lowercased()
            results = serviceResults.filter {
                $0.label.lowercased().contains(query)
                    || $0.spaceName.lowercased().contains(query)
            }
        }

        // Keep the highlight in range when the result set shrinks (e.g. a
        // service was removed or moved while the switcher is open). onChange of
        // searchText resets the index to 0, but a membership/rename recompute
        // doesn't — an out-of-range index would highlight nothing and send Enter
        // to the wrong (or no) target.
        if selectedIndex >= results.count {
            selectedIndex = max(0, results.count - 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)
                .accessibilityHidden(true)

            TextField("Jump to service...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit {
                    selectCurrent()
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        Text("No matching services")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.rowHeight)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button {
                                selectResult(result)
                            } label: {
                                QuickSwitcherRow(
                                    result: result,
                                    isHighlighted: index == selectedIndex
                                )
                            }
                            .buttonStyle(.plain)
                            // The result's own id, which ForEach already uses.
                            // `.id(index)` here overrode it, so the first row
                            // kept the service it showed before a filter.
                            .id(result.id)
                            .onHover { hovering in
                                if hovering { selectedIndex = index }
                            }
                            .accessibilityLabel("\(result.label) in \(result.spaceName)")
                            .accessibilityHint("Switch to this service")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedIndex) { _, newValue in
                guard results.indices.contains(newValue) else { return }
                proxy.scrollTo(results[newValue].id, anchor: .center)
            }
        }
    }

    private func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
        // Announce the newly highlighted item for VoiceOver users
        let result = results[selectedIndex]
        AccessibilityNotification.Announcement("\(result.label) in \(result.spaceName)").post()
    }

    private func selectCurrent() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        selectResult(results[selectedIndex])
    }

    private func selectResult(_ result: QuickSwitcherResult) {
        // A global service shows in every space, so the space stays as it is.
        if let spaceID = result.spaceID { appState.selectedSpaceID = spaceID }
        appState.selectedServiceID = result.serviceID
        dismiss()
    }
}

struct QuickSwitcherResult: Identifiable {
    let id: String
    let label: String
    let spaceName: String
    let spaceEmoji: String
    let serviceID: UUID
    /// Nil for a global service.
    let spaceID: UUID?
    let iconData: Data?
}

private struct QuickSwitcherRow: View {
    let result: QuickSwitcherResult
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.control))

            VStack(alignment: .leading, spacing: 1) {
                Text(result.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(result.spaceEmoji)
                        .font(.caption2)
                    Text(result.spaceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: ChorusRadius.icon)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: QuickSwitcherView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: ChorusRadius.control)
                .fill(isHighlighted ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Color.clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconView: some View {
        if let data = result.iconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text(String(result.label.prefix(1)).uppercased())
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: ChorusRadius.control)
                        .fill(.tint)
                )
        }
    }
}
