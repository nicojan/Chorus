import SwiftUI

/// The production mail interaction wiring, also hosted without launch UI in tests.
struct MailLinkPresentation: ViewModifier {
    let appState: AppState
    @State private var displayedChoice: AppState.PendingMailLink?

    func body(content: Content) -> some View {
        let choice = displayedChoice
        content.sheet(isPresented: Binding(
            get: { !appState.isLocked && displayedChoice != nil },
            set: { shown in
                guard !shown, let choice, displayedChoice?.id == choice.id else { return }
                displayedChoice = nil
                appState.cancelMailLink(choice.id)
            }
        )) {
            if !appState.isLocked, let choice {
                MailServiceChooser(request: choice).environment(appState)
            }
        }
        .task(id: appState.pendingMailLink?.id) {
            displayedChoice = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            displayedChoice = appState.pendingMailLink
        }
        .modifier(MailLinkErrorPresentation(appState: appState))
    }
}

/// Keeps the displayed error separate from the next queued interaction, so
/// SwiftUI can close one alert before presenting another.
struct MailLinkErrorPresentation: ViewModifier {
    let appState: AppState
    @State private var displayedError: AppState.MailLinkError?

    func body(content: Content) -> some View {
        let error = displayedError
        content.alert(
            "Mail link unavailable",
            isPresented: Binding(
                get: { !appState.isLocked && displayedError != nil },
                set: { shown in
                    guard !shown, let error, displayedError?.id == error.id else { return }
                    displayedError = nil
                    appState.dismissMailLinkError(error.id)
                }
            ),
            presenting: error
        ) { _ in
            // The presentation binding is the only completion path, including
            // Return/Escape. Its captured identity makes late delivery harmless.
            Button("OK", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { error in
            Text(error.message)
        }
        .task(id: appState.mailLinkError?.id) {
            displayedError = nil
            // Give the dismissed presentation a separate SwiftUI update before
            // making the next error visible, even when its message is identical.
            await Task.yield()
            guard !Task.isCancelled else { return }
            displayedError = appState.mailLinkError
        }
    }
}

private struct MailServiceChooser: View {
    @Environment(AppState.self) private var appState
    let request: AppState.PendingMailLink

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Write email with")
                .font(.headline)
            Text("Choose the signed-in service that should open this draft.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(request.candidates) { candidate in
                    Button {
                        appState.chooseMailService(candidate.serviceID, requestID: request.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.label)
                                if !candidate.chooserSubtitle.isEmpty {
                                    Text(candidate.chooserSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(candidate.chooserSubtitle.isEmpty
                        ? candidate.label
                        : "\(candidate.label), \(candidate.chooserSubtitle)")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    appState.cancelMailLink(request.id)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
