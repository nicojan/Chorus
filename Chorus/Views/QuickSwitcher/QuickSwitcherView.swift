import SwiftUI
import SwiftData

struct QuickSwitcherView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Query private var allLinks: [SpaceServiceLink]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var results: [QuickSwitcherResult] = []

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(minWidth: 420, maxWidth: 420, minHeight: 280, maxHeight: 480)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onChange(of: searchText) {
            selectedIndex = 0
            recomputeResults()
        }
        .onChange(of: allLinks.count) {
            recomputeResults()
        }
        .onAppear {
            recomputeResults()
        }
    }

    private func recomputeResults() {
        let serviceResults = allLinks
            .filter { $0.modelContext != nil && $0.service.modelContext != nil }
            .map { link in
                QuickSwitcherResult(
                    id: "\(link.space.id)-\(link.service.id)",
                    label: link.service.label,
                    spaceName: link.space.name,
                    spaceEmoji: link.space.emoji,
                    serviceID: link.service.id,
                    spaceID: link.space.id,
                    iconData: link.service.customIconData ?? link.service.fetchedIconData
                )
            }

        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            results = serviceResults
            return
        }

        let query = searchText.lowercased()
        results = serviceResults.filter {
            $0.label.lowercased().contains(query)
                || $0.spaceName.lowercased().contains(query)
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
                            .padding(.vertical, 40)
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
                            .id(index)
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
                proxy.scrollTo(newValue, anchor: .center)
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
        appState.selectedSpaceID = result.spaceID
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
    let spaceID: UUID
    let iconData: Data?
}

private struct QuickSwitcherRow: View {
    let result: QuickSwitcherResult
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))

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
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
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
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.tint)
                )
        }
    }
}
