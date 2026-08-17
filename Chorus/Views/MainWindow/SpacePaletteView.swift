import SwiftUI
import SwiftData

/// The words and the keyboard arithmetic behind the space palette. Split out
/// from the view so both can be pinned by a test, the same way
/// `ServiceAccessibility` is.
enum SpacePalette {
    /// The digit that picks the row at `index`, or nil past the ninth. There is
    /// no ⌘0 row; a tenth space is reached by arrow or by click.
    static func shortcutDigit(forIndex index: Int) -> Int? {
        guard (0..<9).contains(index) else { return nil }
        return index + 1
    }

    /// The row a digit picks, or nil when the digit reaches past the last row.
    ///
    /// Returning nil matters as much as returning an index. The digits are
    /// palette-local (decided 2026-08-17): `⌘1`–`⌘9` still switches services
    /// globally through `KeyboardShortcutManager`, and the palette only borrows
    /// them while it is open. A digit with no row behind it has to go
    /// unhandled rather than be swallowed.
    static func index(forDigit digit: Int, rowCount: Int) -> Int? {
        guard (1...9).contains(digit) else { return nil }
        let index = digit - 1
        return index < rowCount ? index : nil
    }

    static func subtitle(serviceCount: Int) -> String {
        switch serviceCount {
        case 0: return "No services"
        case 1: return "1 service"
        default: return "\(serviceCount) services"
        }
    }

    /// Everything the row shows, spoken. Mirrors `ServiceAccessibility.label`.
    static func rowLabel(name: String, serviceCount: Int, badgeCount: Int, isMuted: Bool) -> String {
        var parts = [name, subtitle(serviceCount: serviceCount)]
        if badgeCount > 0 {
            parts.append(badgeCount == 1 ? "1 unread" : "\(badgeCount) unread")
        }
        if isMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// The space switcher the rail header opens.
///
/// One of the three homes the spaces have, and the only one that is not always
/// on screen — see `SpacesPresentation`. It adds the keyboard to `SpaceListRows`
/// (arrows, Return, Escape, ⌘1–⌘9) and a way to make a new space; the rows,
/// their badges, drag-to-reorder and the context menu are shared with the two
/// rail presentations.
///
/// The owner presents it, and owns any sheet it asks for:
///
/// ```swift
/// SpaceHeaderView(…, isPaletteOpen: showingPalette) { showingPalette = true }
///     .popover(isPresented: $showingPalette) {
///         SpacePaletteView(selectedSpaceID: $selectedSpaceID, onEditSpace: …)
///     }
/// ```
///
/// A sheet cannot be raised from inside a popover — the popover closes and takes
/// the sheet with it — so editing, deleting and adding are reported upward
/// instead of handled here.
struct SpacePaletteView: View {
    @Binding var selectedSpaceID: UUID?
    /// Reported upward rather than handled: see the note above about sheets.
    var onEditSpace: (Space) -> Void = { _ in }
    var onDeleteSpace: (Space) -> Void = { _ in }
    var onAddSpace: () -> Void = {}

    /// Read only for the keyboard: how many rows there are, and which space a
    /// digit or an arrow lands on. The rows themselves, and everything that
    /// hangs off them, are `SpaceListRows`.
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Environment(\.dismiss) private var dismiss

    /// The row the keyboard is on. Separate from `selectedSpaceID`, which only
    /// changes when a row is actually picked — arrowing through the list should
    /// not switch spaces underneath the palette.
    @State private var highlightedIndex = 0
    @FocusState private var isFocused: Bool

    static let paletteWidth: CGFloat = 260
    /// Radius 14 is the spec's one value for sheets and palettes.
    private static let cornerRadius = ChorusRadius.surface

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            addSpaceButton
        }
        .frame(width: Self.paletteWidth)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            highlightedIndex = spaces.firstIndex { $0.id == selectedSpaceID } ?? 0
            isFocused = true
        }
        .onKeyPress(phases: .down) { handleKey($0) }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    SpaceListRows(
                        selectedSpaceID: $selectedSpaceID,
                        style: .palette,
                        highlightedIndex: highlightedIndex,
                        onHover: { highlightedIndex = $0 },
                        onSelect: { dismiss() },
                        onEditSpace: { space in
                            dismiss()
                            onEditSpace(space)
                        },
                        onDeleteSpace: { space in
                            dismiss()
                            onDeleteSpace(space)
                        }
                    )
                }
                .padding(6)
            }
            // 4 rows and a bit, so a fifth space reads as "there is more here"
            // rather than being cut off flush.
            .frame(maxHeight: 220)
            .onChange(of: highlightedIndex) { _, new in
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }

    private var addSpaceButton: some View {
        Button {
            dismiss()
            onAddSpace()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 20)
                Text("New Space")
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New space")
    }

    // MARK: - Keyboard

    /// Arrows move the highlight, Return picks it, Escape closes, and ⌘1–⌘9 pick
    /// a row outright. The digits are borrowed only while this is open; anything
    /// else is left unhandled so it reaches the shortcuts underneath.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            guard let digit = Int(press.characters),
                  let index = SpacePalette.index(forDigit: digit, rowCount: spaces.count)
            else { return .ignored }
            select(spaces[index])
            return .handled
        }

        switch press.key {
        case .upArrow:
            moveHighlight(-1)
            return .handled
        case .downArrow:
            moveHighlight(1)
            return .handled
        case .return:
            guard spaces.indices.contains(highlightedIndex) else { return .handled }
            select(spaces[highlightedIndex])
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            return .ignored
        }
    }

    private func moveHighlight(_ offset: Int) {
        guard !spaces.isEmpty else { return }
        highlightedIndex = (highlightedIndex + offset + spaces.count) % spaces.count
        let space = spaces[highlightedIndex]
        AccessibilityNotification.Announcement(space.name).post()
    }

    private func select(_ space: Space) {
        selectedSpaceID = space.id
        dismiss()
    }

}
