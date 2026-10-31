import Foundation

// MARK: - Custom CSS presets and per-service defaults

/// Baked-in default CSS for known catalog services, plus the rule that decides
/// what actually gets injected for a service. Kept as pure functions so the
/// resolution logic is unit-testable without a running web view.
enum ServiceCSSDefaults {
    /// The default CSS shipped for a catalog service, or nil when it has none.
    static func css(forCatalogID id: String?) -> String? {
        switch id {
        case "linkedin": return linkedInMessaging
        default: return nil
        }
    }

    /// The CSS to inject for a service: the instance's own CSS when set,
    /// otherwise the baked-in default. A blank result injects nothing — an
    /// explicit "no CSS" override.
    static func effectiveCSS(instanceCSS: String?, catalogID: String?) -> String? {
        let raw = instanceCSS ?? css(forCatalogID: catalogID)
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
    }

    /// Trims LinkedIn down to just its messaging pane, filling the window like a
    /// dedicated chat app: hides the global nav and right rail, and expands the
    /// conversation list + thread to full width and height. Selectors are
    /// LinkedIn's stable semantic names, verified against the live page.
    static let linkedInMessaging = """
    #global-nav, .global-nav { display: none !important; }
    .authentication-outlet { padding-top: 0 !important; }
    /* Fill the window by chaining height:100% from html all the way down to the
       message panes — not 100vh, which binds to the WKWebView's initial zero
       frame and never recomputes, and not flex/grid stretch, which doesn't hold
       at every LinkedIn breakpoint (its content row is block, not grid, when
       narrow). Scoped with :has(#messaging)/#messaging so only the messaging
       page is height-constrained, never the feed. Responsive at any size. */
    html:has(#messaging), body:has(#messaging) { height: 100% !important; }
    .application-outlet:has(#messaging), .authentication-outlet:has(#messaging) { height: 100% !important; }
    #messaging.scaffold-layout,
    #messaging .scaffold-layout__inner,
    #messaging .scaffold-layout__content,
    #messaging .scaffold-layout__list-detail,
    #messaging .scaffold-layout__list-detail-container,
    #messaging .scaffold-layout__list-detail-inner,
    #messaging .scaffold-layout__detail { height: 100% !important; }
    .scaffold-layout__inner { margin-left: 0 !important; margin-right: 0 !important; max-width: none !important; width: 100% !important; }
    /* Single column, and kill the grid column-gap: when the right rail is hidden
       its grid track collapses to 0 but the gap stays, leaving a gray strip on
       the right (most visible when zoomed out into the wide breakpoint). */
    .scaffold-layout__content { grid-template-columns: minmax(0, 1fr) !important; column-gap: 0 !important; grid-column-gap: 0 !important; margin-top: 0 !important; }
    .scaffold-layout__aside { display: none !important; }
    .scaffold-layout__content, .scaffold-layout__list-detail, .scaffold-layout__list-detail-container, .scaffold-layout__list-detail-inner { max-width: none !important; width: 100% !important; }
    .msg-overlay-list-bubble, .msg-overlay { display: none !important; }
    """
}

