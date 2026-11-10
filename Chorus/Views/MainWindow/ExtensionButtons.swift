import AppKit
import ChorusEngine
import SwiftUI
import WebKit

/// One button per running extension that has one, in the toolbar beside the
/// downloads button. A click runs the extension's action on the page on
/// screen, which usually opens its popup under the button.
struct ExtensionButtons: View {
    let webView: WKWebView?
    @Environment(AppState.self) private var appState

    var body: some View {
        if #available(macOS 15.4, *), let host = appState.extensions.host {
            ExtensionButtonRow(host: host, webView: webView, order: appState.extensions.enabledIDs)
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionButtonRow: View {
    let host: WebExtensionHost
    let webView: WKWebView?
    let order: [UUID]

    var body: some View {
        ForEach(host.toolbarItems(for: webView, order: order)) { item in
            Button {
                host.performAction(item.id, on: webView)
            } label: {
                icon(for: item)
                    .frame(width: 16, height: 14)
                    .navCircle()
                    .overlay(alignment: .topTrailing) { badge(item.badgeText) }
            }
            .buttonStyle(.chromeCircle)
            .disabled(!item.isEnabled)
            .help(item.label)
            .accessibilityLabel(item.label)
            .background(PopupAnchor { host.setAnchor($0, for: item.id) })
        }
    }

    @ViewBuilder
    private func icon(for item: WebExtensionToolbarItem) -> some View {
        if let image = item.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12, weight: .medium))
        }
    }

    @ViewBuilder
    private func badge(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 12, minHeight: 12)
                .background(Capsule().fill(Color.red))
                .offset(x: 4, y: -3)
                .accessibilityHidden(true)
        }
    }
}

/// Hands its AppKit view to the host, so an extension's popup can point at
/// the button that opened it.
private struct PopupAnchor: NSViewRepresentable {
    let register: (NSView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}
}
