import AppKit
import ChorusEngine
import SwiftUI
import UniformTypeIdentifiers

/// The toolbar's download control: absent until something downloads this
/// session, then an arrow that rings with progress while files come in, and a
/// list of them on click.
struct DownloadsButton: View {
    @Environment(AppState.self) private var appState
    @State private var isShowingList = false

    private var center: DownloadCenter { appState.downloadCenter }

    var body: some View {
        if !center.items.isEmpty {
            Button {
                isShowingList.toggle()
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 14)
                    .navCircle()
                    // The ring runs just inside the circle's edge.
                    .overlay {
                        if center.hasRunning {
                            ProgressRing(fraction: center.overallFraction)
                                .frame(width: ChorusNav.buttonSize - 4, height: ChorusNav.buttonSize - 4)
                        }
                    }
            }
            .buttonStyle(.chromeCircle)
            .help("Downloads")
            .accessibilityLabel(center.hasRunning ? "Downloads, in progress" : "Downloads")
            .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
                DownloadList(center: center)
            }
        }
    }
}

/// A thin ring over the arrow: the share done when the size is known, a short
/// spinning arc when it isn't.
private struct ProgressRing: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
        } else {
            SpinningArc()
        }
    }
}

/// A quarter arc that turns once a second, run by Core Animation. As a
/// SwiftUI `repeatForever` it made SwiftUI update, and the window lay itself
/// out again, on every frame for as long as the download ran (see
/// `CountPulse`).
struct SpinningArc: NSViewRepresentable {
    static var lineWidth: CGFloat { 2 }
    static var period: CFTimeInterval { 1 }

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView() }
    func updateNSView(_ view: SpinningArcView, context: Context) {}
}

final class SpinningArcView: NSView {
    static var animationKey: String { "chorus.downloadSpin" }
    let arc = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = SpinningArc.lineWidth
        arc.lineCap = .round
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        arc.frame = bounds
        let inset = SpinningArc.lineWidth / 2
        // A quarter turn from the top, clockwise on screen.
        let path = CGMutablePath()
        let radius = max(0, min(bounds.width, bounds.height) / 2 - inset)
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        arc.path = path
        startSpin()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startSpin()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    private func startSpin() {
        updateColor()
        guard window != nil, bounds.size != .zero, arc.animation(forKey: Self.animationKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // Negative turns clockwise in AppKit's upward y.
        spin.toValue = -2 * Double.pi
        spin.duration = SpinningArc.period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: Self.animationKey)
    }
}

private struct DownloadList: View {
    let center: DownloadCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .disabled(!center.items.contains { !$0.isRunning })
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(center.items) { item in
                        DownloadRow(item: item, center: center)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    let item: DownloadCenter.Item
    let center: DownloadCenter

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: fileIcon)
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isRunning {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(status)
                    .font(ChorusType.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if item.isRunning {
                iconButton("xmark.circle.fill", label: "Cancel download") { center.cancel(item.id) }
            } else if item.state == .finished {
                iconButton("magnifyingglass.circle.fill", label: "Show in Finder") { center.reveal(item.id) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { center.open(item.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open") { center.open(item.id) }
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    /// The service it came from, then what happened to it.
    private var status: String {
        let outcome: String
        switch item.state {
        case .running:
            outcome = item.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Downloading"
        case .finished:
            outcome = "Done"
        case .failed(let message):
            outcome = "Failed: \(message)"
        case .cancelled:
            outcome = "Cancelled"
        }
        guard let serviceName = item.serviceName else { return outcome }
        return "\(serviceName) · \(outcome)"
    }

    private var fileIcon: NSImage {
        if let url = item.destination, item.state == .finished {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = (item.filename as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.chromeCircle)
        .help(label)
        .accessibilityLabel(label)
    }
}
