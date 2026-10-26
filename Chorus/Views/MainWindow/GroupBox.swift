import SwiftUI

/// The box round a service group's rows: the card the global services sit in
/// within the space strip (`.railCard()`, padded `ChorusCard.railPadding` on
/// every side so a row's 8 point fill sits inside the card's 14 point corners).
/// In the top bar it is the same card round a run of tabs.
///
/// The box lays its content out along `axis`, at the rail's own spacing, so the
/// caller hands it the rows and nothing else. The rows keep every modifier they
/// have outside a box.
struct GroupBox<Content: View>: View {
    /// The group's name, or nil for a group with none. A nil name draws and
    /// says nothing.
    let name: String?
    let axis: Axis
    /// Whether there is room to draw the name: above the box in the sidebar and
    /// the all-services list, at the start of it in the top bar. Without room,
    /// as in the icon-only rail, the name goes in the tooltip and the spoken
    /// label only.
    let showsName: Bool
    /// A drag is over the box and letting go would put the service in it.
    let isLit: Bool
    /// Space between the card's side edges and the rows. The rail's padding,
    /// except inside an all-services card too narrow for a second inset.
    var sideInset: CGFloat = ChorusCard.railPadding
    @ViewBuilder let content: Content

    /// Height of the name over a vertical box, as the all-services heading.
    static var nameHeight: CGFloat { 22 }

    var body: some View {
        Group {
            if axis == .vertical {
                vertical
            } else {
                horizontal
            }
        }
        .modifier(GroupBoxNaming(name: name, inTooltip: !showsName))
    }

    private var vertical: some View {
        card(VStack(spacing: 2) { content }, vertical: ChorusCard.railPadding)
            // The name sits over the box in the space it is given, so a long one
            // truncates at the box's width rather than widening the rail.
            .padding(.top, drawsName ? Self.nameHeight : 0)
            .overlay(alignment: .topLeading) {
                if drawsName { nameLabel.frame(height: Self.nameHeight) }
            }
    }

    private var horizontal: some View {
        card(
            HStack(spacing: 4) {
                if drawsName { nameLabel }
                content
            },
            vertical: 2
        )
    }

    private func card(_ rows: some View, vertical: CGFloat) -> some View {
        rows
            .padding(.horizontal, axis == .vertical ? sideInset : 2)
            .padding(.vertical, vertical)
            .railCard()
            .overlay {
                RoundedRectangle(cornerRadius: ChorusCard.cornerRadius, style: .continuous)
                    .strokeBorder(isLit ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 2)
                    .allowsHitTesting(false)
            }
    }

    private var drawsName: Bool { showsName && name != nil }

    /// Set like the all-services heading: the row size, bold, grey. Lined up
    /// with the row icons in the sidebar; inset from the card's edge in the bar.
    private var nameLabel: some View {
        Text(name ?? "")
            .font(ChorusType.label)
            .fontWeight(.bold)
            .foregroundStyle(ChorusColor.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, axis == .vertical ? sideInset + 8 : 8)
            .padding(.trailing, axis == .vertical ? sideInset : 2)
            .accessibilityHidden(true)
    }
}

/// The box as one container to VoiceOver, named when the group has a name, and
/// the name in the tooltip where the box has no room to draw it.
private struct GroupBoxNaming: ViewModifier {
    let name: String?
    let inTooltip: Bool

    func body(content: Content) -> some View {
        if let name {
            content
                .help(inTooltip ? name : "")
                .accessibilityElement(children: .contain)
                .accessibilityLabel(name)
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

/// Which of a space's links are in a group the rail can draw, and what each
/// group is called. A link counts as grouped only while its group's row exists,
/// is live, and sits in the same space as the link: anything else is no group.
struct RailGroupLookup {
    /// Each drawable group's name by id; nil for a group with none.
    private let names: [UUID: String?]

    init(groups: [ServiceGroup], spaceID: UUID) {
        self.init(
            entries: groups
                .filter { $0.modelContext != nil && !$0.isDeleted }
                .map { (id: $0.id, spaceID: $0.spaceID, name: $0.name) },
            spaceID: spaceID
        )
    }

    init(entries: [(id: UUID, spaceID: UUID, name: String?)], spaceID: UUID) {
        var names: [UUID: String?] = [:]
        for entry in entries where entry.spaceID == spaceID {
            let trimmed = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            names[entry.id] = (trimmed?.isEmpty ?? true) ? String?.none : trimmed
        }
        self.names = names
    }

    /// The group a link with this `groupID` is drawn in, or nil.
    func group(of groupID: UUID?) -> UUID? {
        guard let groupID, names[groupID] != nil else { return nil }
        return groupID
    }

    /// The group's name, nil when it has none or is not drawable.
    func name(of groupID: UUID) -> String? {
        names[groupID] ?? nil
    }

    /// The rows and boxes of one space's list.
    func runs(_ items: [RailItem], dragged: UUID? = nil) -> [RailRun] {
        var linkGroups: [UUID: UUID] = [:]
        for case .member(let link, _) in items {
            if let group = group(of: link.groupID) { linkGroups[link.id] = group }
        }
        return RailRuns.runs(items, groupOf: { linkGroups[$0] }, nameOf: { name(of: $0) }, dragged: dragged)
    }

    /// What VoiceOver adds to a member of a box: the group's name, or the other
    /// services in the box.
    static func context(
        for item: RailItem,
        name: String?,
        in items: [RailItem]
    ) -> ServiceAccessibility.GroupContext? {
        guard case .member = item else { return nil }
        if let name { return .named(name) }
        let others = items.filter { $0.id != item.id }.compactMap { $0.service?.label }
        return .unnamed(others: others)
    }
}
