import SwiftUI
import SwiftData

struct SpaceStripView: View {
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Binding var selectedSpaceID: UUID?

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
                .frame(height: 8)

            ForEach(spaces) { space in
                SpaceButton(
                    space: space,
                    isSelected: selectedSpaceID == space.id
                ) {
                    selectedSpaceID = space.id
                }
            }

            Spacer()
        }
        .frame(width: 48)
        .background(.background)
    }
}

private struct SpaceButton: View {
    let space: Space
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(space.emoji)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .help(space.name)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.2)
        } else if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}
