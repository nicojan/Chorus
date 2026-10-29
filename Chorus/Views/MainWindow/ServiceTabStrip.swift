import ChorusEngine
import SwiftUI

/// The row of tabs across the top of a service's card: the service's own page
/// first, then each page it opened with `window.open`. Shown only while the
/// service has a tab open.
struct ServiceTabStrip: View {
    let serviceLabel: String
    let tabs: ServiceTabs
    let onClose: (UUID) -> Void

    static let height: CGFloat = 32

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ServiceTabButton(
                    title: serviceLabel,
                    isSelected: tabs.selectedID == nil,
                    onSelect: { tabs.select(nil) },
                    onClose: nil
                )
                ForEach(tabs.tabs) { tab in
                    ServiceTabButton(
                        title: Self.title(for: tab),
                        isSelected: tabs.selectedID == tab.id,
                        onSelect: { tabs.select(tab.id) },
                        onClose: { onClose(tab.id) }
                    )
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            ChorusColor.hairline.frame(height: 1)
        }
    }

    /// The page's title, or its host until the title arrives.
    static func title(for tab: ServiceTab) -> String {
        if let title = tab.title, !title.isEmpty { return title }
        return tab.webView.url?.host ?? "New Tab"
    }
}

private struct ServiceTabButton: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(ChorusType.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : ChorusColor.secondaryText)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ChorusColor.secondaryText)
                .help("Close Tab")
                .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 220, minHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: ChorusRadius.control, style: .continuous)
                .fill(isSelected ? ChorusColor.selectedFill : (isHovered ? ChorusColor.hoverFill : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: ChorusRadius.control, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            if let onClose {
                Button("Close Tab", action: onClose)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }
}
