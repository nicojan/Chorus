import ChorusEngine
import SwiftUI

/// The sheets and the alert of Settings > Extensions, kept off the `Form`:
/// the macOS 15 compiler gives up on a long modifier chain there.
///
/// Two sheets: the view's own, and Get's confirm sheet, which the catalog
/// controller holds. Get is disabled while either is up, so they never both
/// show.
struct ExtensionSettingsDialogs: ViewModifier {
    @Binding var sheet: ExtensionSheet?
    @Binding var error: SettingsError?
    let onSafariPick: (SafariExtensionScanner.Found) -> Void
    let onConfirm: (PendingExtension, Bool) -> Void
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet) { ownSheet($0) }
            .sheet(item: pendingInstall) { pending in
                ExtensionConfirmSheet(pending: pending) { agreed in finishInstall(agreed: agreed) }
            }
            .alert(error?.title ?? "", isPresented: isErrorShown, presenting: error) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.message)
            }
    }

    /// Get's confirm sheet answered. A list that would not save is shown in
    /// the same alert as any other failed add.
    private func finishInstall(agreed: Bool) {
        let controller = appState.extensionCatalog
        let shown = $error
        Task {
            do {
                try await controller.finishInstall(agreed: agreed)
            } catch {
                shown.wrappedValue = SettingsError(title: "Chorus couldn't add the extension",
                                                   message: ExtensionManager.describe(error))
            }
        }
    }

    @ViewBuilder
    private func ownSheet(_ shown: ExtensionSheet) -> some View {
        switch shown {
        case .safariList:
            SafariExtensionPicker(isAdded: appState.extensions.contains, onPick: onSafariPick)
        case .confirm(let pending):
            ExtensionConfirmSheet(pending: pending) { onConfirm(pending, $0) }
        case .reviewUpdate(let recordID, let folder):
            ExtensionUpdateSheet(recordID: recordID, folder: folder, onClose: { sheet = nil }, onError: { title, message in
                error = SettingsError(title: title, message: message)
            })
        }
    }

    /// The controller's pending install. Closing the sheet any other way
    /// than its buttons cancels the install.
    private var pendingInstall: Binding<PendingExtension?> {
        let controller = appState.extensionCatalog
        return Binding(
            get: { controller.pendingInstall },
            set: { if $0 == nil { controller.cancelInstall() } }
        )
    }

    private var isErrorShown: Binding<Bool> {
        Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )
    }
}
