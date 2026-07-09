import Foundation

/// Central switches for platform capabilities that depend on an Apple approval
/// or build configuration, so feature-gated UI is driven from one place rather
/// than scattered booleans.
enum AppCapabilities {
    /// Passkey (WebAuthn) sign-in works inside `WKWebView` only when the app
    /// holds the Apple-managed `com.apple.developer.web-browser.public-key-credential`
    /// entitlement, which must be requested from and granted by Apple. Until
    /// then, passkey prompts fail inside Chorus, so the UI steers users to
    /// password + two-factor sign-in.
    ///
    /// Flip to `true` once the entitlement is granted, added to the
    /// entitlements file, and provisioned. See DISTRIBUTION.md.
    static let passkeysSupported = false

    /// User-facing explanation shown where the passkey limitation is relevant
    /// (currently the Add Service sheet).
    static let passkeyUnavailableNotice =
        "Passkey sign-in isn’t available yet. Log in with your password and two-factor code instead."

    /// Fuller wording for the passive banner shown the first time a service is
    /// opened, where there's room to say why passkeys don't work.
    static let passkeyUnavailableBanner =
        "Passkeys aren't available for sign-in here. Apple doesn't let apps like Chorus use them, so sign in with your password or another method."
}
