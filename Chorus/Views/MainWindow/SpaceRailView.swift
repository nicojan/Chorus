import SwiftUI
import SwiftData

/// The spaces in a rail of their own, beside the service rail or above the tab
/// bar — `SpacesPresentation.ownRail`.
///
/// This is the old two-rail arrangement back, by request, but not the old rail:
/// the column that `SpaceStripView` drew was 52 points of unlabelled emoji,
/// which the UX audit rated its severity 3 finding. These are the same named
/// rows the palette and the service rail draw, so a space says what it is and
/// what it is holding for you without a tooltip.
///
/// The sheets it needs are reported upward, the way the palette's are: this view
/// can be inside a popover-free rail, but keeping one owner for the editors
/// means one place where a half-finished space can be cancelled.
struct SpaceRailView: View {
    @Binding var selectedSpaceID: UUID?
    var axis: Axis = .vertical
    /// Inset applied to the content (top for the vertical rail, leading for the
    /// horizontal bar) to clear the window traffic lights, kept inside so the
    /// background and dividers still run full-length.
    var contentInset: CGFloat = 0

    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Environment(AppState.self) private var appState

    /// Read only to size the gap the donation button needs at the far right of
    /// the horizontal bar; `ContentView` owns the button itself.
    @AppStorage(SupportButtonVisibility.defaultsKey) private var showSupportButton = true

    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?

    /// Narrower than the 240 point service rail: these rows carry a name, a
    /// badge and nothing else, and the two rails side by side have to leave the
    /// web content the width it came for.
    static let railWidth: CGFloat = 180
    /// The horizontal bar: a 28 point chip with 5 points clear above and below.
    static let barHeight: CGFloat = 38

    var body: some View {
        content
            .sheet(isPresented: $showingAddSpace) {
                SpaceEditorSheet(editingSpace: nil, selectedSpaceID: $selectedSpaceID)
            }
            .sheet(item: $editingSpace) { space in
                SpaceEditorSheet(editingSpace: space, selectedSpaceID: $selectedSpaceID)
            }
            .confirmationDialog(
                "Delete \(confirmingDeleteSpace?.name ?? "space")?",
                isPresented: Binding(
                    get: { confirmingDeleteSpace != nil },
                    set: { if !$0 { confirmingDeleteSpace = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let space = confirmingDeleteSpace {
                        appState.deleteSpace(space.id)
                    }
                    confirmingDeleteSpace = nil
                }
            } message: {
                Text("Services in this space won't be deleted, but the space will be removed.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spaces")
    }

    @ViewBuilder
    private var content: some View {
        if axis == .vertical {
            verticalBody
        } else {
            horizontalBody
        }
    }

    private var verticalBody: some View {
        VStack(spacing: 0) {
            Text("Spaces")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 14 + contentInset)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    rows
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()

            addSpaceButton
                .padding(.vertical, 6)
        }
        .frame(width: Self.railWidth)
        .background(.background)
    }

    private var horizontalBody: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    chips
                }
                .padding(.leading, 8 + contentInset)
                .padding(.trailing, 4)
            }

            addSpaceButton
                // This bar is the topmost one in this layout, so the donation
                // button lands in its top-right corner. Leave it the room, and
                // fall back to the plain gap when Settings has hidden it.
                .padding(.trailing, showSupportButton ? SupportButtonVisibility.reservedWidth : 8)
        }
        .frame(height: Self.barHeight)
        // The OS window drag is off in the bar layouts, so this bar needs the
        // same handle the tab bar has or the top of the window stops moving it.
        .background(WindowDragHandle())
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var rows: some View {
        SpaceListRows(
            selectedSpaceID: $selectedSpaceID,
            style: .rail,
            highlightedIndex: nil,
            onEditSpace: { editingSpace = $0 },
            onDeleteSpace: { confirmingDeleteSpace = $0 }
        )
    }

    private var chips: some View {
        ForEach(spaces.filter { $0.modelContext != nil }) { space in
            let muted = space.isMutedEffective
            let serviceIDs = appState.servicesForSpace(space.id).map(\.id)
            SpaceChipCell(
                space: space,
                badgeCount: muted ? 0 : appState.badgeManager.aggregateCount(for: serviceIDs),
                isMuted: muted,
                isCurrent: space.id == selectedSpaceID
            ) {
                selectedSpaceID = space.id
            }
            .contextMenu {
                SpaceContextMenu(
                    space: space,
                    canDelete: spaces.count > 1,
                    onEdit: { editingSpace = space },
                    onDelete: { confirmingDeleteSpace = space }
                )
            }
        }
    }

    private var addSpaceButton: some View {
        Button {
            showingAddSpace = true
        } label: {
            Group {
                if axis == .vertical {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 20, height: 20)
                        Text("Add space")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: Self.railWidth - 16, height: 30)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: SpaceChipCell.chipHeight)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New space")
        .accessibilityLabel("New space")
    }
}
