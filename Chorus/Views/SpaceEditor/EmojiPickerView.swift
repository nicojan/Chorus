import SwiftUI

struct EmojiPickerView: View {
    @Binding var selectedEmoji: String

    @State private var searchText = ""
    @State private var selectedCategoryID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("recentEmojis") private var recentEmojisData: Data = Data()

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 10)

    private var recentEmojis: [String] {
        (try? JSONDecoder().decode([String].self, from: recentEmojisData)) ?? []
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            searchField
            categoryTabs
            emojiGrid
            systemPickerButton
        }
        // The system Character Viewer ("More Emoji…") inserts the chosen emoji
        // into the first responder — which is the search field. Detect when the
        // search text is actually emoji (rather than a keyword query) and apply
        // it as the selection instead of leaving it stranded in the search box.
        .onChange(of: searchText) { _, newValue in
            if let emoji = Self.emojiToPromote(from: newValue) {
                selectedEmoji = emoji
                addToRecents(emoji)
                searchText = ""
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
                .accessibilityHidden(true)
            TextField("Search emoji...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if !recentEmojis.isEmpty {
                    categoryTab(id: "recent", icon: "clock", label: "Recent")
                }
                ForEach(EmojiData.categories) { category in
                    categoryTab(id: category.id, icon: category.icon, label: category.name)
                }
            }
            .padding(.horizontal, 2)
        }
        .opacity(isSearching ? 0.4 : 1.0)
        .disabled(isSearching)
    }

    private func categoryTab(id: String, icon: String, label: String) -> some View {
        Button {
            selectedCategoryID = id
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 28, height: 24)
                .foregroundStyle(selectedCategoryID == id ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selectedCategoryID == id ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(Color.clear))
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selectedCategoryID == id ? .isSelected : [])
    }

    private var emojiGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if isSearching {
                        let results = EmojiData.search(searchText)
                        if results.isEmpty {
                            Text("No emoji found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        } else {
                            emojiGridSection(emojis: results)
                        }
                    } else {
                        if !recentEmojis.isEmpty {
                            emojiSection(id: "recent", title: "Recent", emojis: recentEmojis.map { EmojiItem($0) })
                        }
                        ForEach(EmojiData.categories) { category in
                            emojiSection(id: category.id, title: category.name, emojis: category.emojis)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedCategoryID) { _, newValue in
                if let id = newValue {
                    if reduceMotion {
                        proxy.scrollTo(id, anchor: .top)
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private func emojiSection(id: String, title: String, emojis: [EmojiItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .id(id)

            emojiGridSection(emojis: emojis)
        }
    }

    private func emojiGridSection(emojis: [EmojiItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(emojis) { item in
                Button {
                    selectedEmoji = item.emoji
                    addToRecents(item.emoji)
                } label: {
                    Text(item.emoji)
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedEmoji == item.emoji
                                    ? AnyShapeStyle(.tint.opacity(0.2))
                                    : AnyShapeStyle(Color.clear))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.keywords.first ?? item.emoji)
                .accessibilityAddTraits(selectedEmoji == item.emoji ? .isSelected : [])
            }
        }
    }

    private var systemPickerButton: some View {
        Button {
            NSApp.orderFrontCharacterPalette(nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 10))
                Text("More Emoji...")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More Emoji")
        .accessibilityHint("Opens the system character palette")
    }

    private func addToRecents(_ emoji: String) {
        var recents = recentEmojis
        recents.removeAll { $0 == emoji }
        recents.insert(emoji, at: 0)
        if recents.count > 20 {
            recents = Array(recents.prefix(20))
        }
        recentEmojisData = (try? JSONEncoder().encode(recents)) ?? Data()
    }

    /// When text lands in the search field that is actually emoji — picked from
    /// the system Character Viewer via "More Emoji…", or pasted/typed directly —
    /// return the emoji to apply as the selection. Returns nil for ordinary
    /// keyword searches so those still filter the grid.
    ///
    /// When several emoji are present, the last one (the most recent Character
    /// Viewer pick) wins.
    static func emojiToPromote(from searchText: String) -> String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let chars = Array(trimmed)
        guard chars.allSatisfy({ $0.isEmojiComposed }),
              chars.contains(where: { $0.isTrueEmoji })
        else { return nil }

        return chars.last.map(String.init)
    }
}

private extension Character {
    /// Every Unicode scalar in this grapheme is part of an emoji sequence —
    /// a base emoji, a skin-tone modifier, a ZWJ/variation selector, or the
    /// combining keycap mark.
    var isEmojiComposed: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.properties.isEmoji
                || scalar.properties.isEmojiModifier
                || scalar.properties.isEmojiModifierBase
                || scalar == "\u{200D}"   // zero-width joiner
                || scalar == "\u{FE0F}"   // emoji variation selector
                || scalar == "\u{FE0E}"   // text variation selector
                || scalar == "\u{20E3}"   // combining enclosing keycap
        }
    }

    /// At least one scalar is a genuine pictographic emoji. Excludes bare ASCII
    /// digits, `#`, and `*`, which report `isEmoji == true` but are only emoji
    /// as keycap sequences.
    var isTrueEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || scalar.value >= 0x1F000
                || scalar == "\u{FE0F}"
        }
    }
}
