//
//  Updater.swift
//  Chorus
//
//  Sparkle auto-update integration for direct (non-App Store) distribution.
//
//  This whole file is gated on `canImport(Sparkle)` so the project keeps
//  compiling before the Sparkle Swift package is added. Once you add the
//  package (Xcode > File > Add Package Dependencies >
//  https://github.com/sparkle-project/Sparkle), `canImport` flips to true and
//  the "Check for Updates…" menu item in ChorusApp lights up automatically.
//
//  Configuration (SUFeedURL, SUPublicEDKey) lives in Info.plist. See
//  DISTRIBUTION.md for the full release/signing pipeline.
//

#if canImport(Sparkle)

import SwiftUI
import Sparkle

/// Publishes whether the updater can currently check for updates, so the menu
/// item can enable/disable itself reactively.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu command. The intermediate view exists so the
/// disabled state binds correctly (a known SwiftUI menu quirk).
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

#endif
