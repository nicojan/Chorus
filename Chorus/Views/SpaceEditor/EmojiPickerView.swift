import SwiftUI

struct EmojiPickerView: View {
    @Binding var selectedEmoji: String

    private let emojis: [(String, [String])] = [
        ("Spaces", ["🌐", "🏢", "🏠", "🎮", "📚", "🎵", "🎨", "💼", "🔬", "🏋️"]),
        ("Objects", ["📁", "📂", "⭐", "💡", "🔧", "📌", "🎯", "🚀", "💎", "🔑"]),
        ("Nature", ["🌱", "🌸", "🌊", "🔥", "❄️", "⚡", "🌙", "☀️", "🍀", "🌺"]),
        ("Symbols", ["❤️", "💙", "💚", "💛", "💜", "🖤", "🤍", "🧡", "💗", "🩵"]),
    ]

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 10)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(emojis, id: \.0) { category, emojiList in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(emojiList, id: \.self) { emoji in
                                Button {
                                    selectedEmoji = emoji
                                } label: {
                                    Text(emoji)
                                        .font(.title3)
                                        .frame(width: 32, height: 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(selectedEmoji == emoji
                                                    ? Color.accentColor.opacity(0.2)
                                                    : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(emoji)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 200)
    }
}
