import Foundation

enum CookieConsentManager {
    static func makeConsentDismissalScript() -> String {
        """
        (function() {
            const SELECTORS = [
                '#onetrust-accept-btn-handler',
                '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
                '#CybotCookiebotDialogBodyButtonAccept',
                '.cc-accept',
                '.cc-btn.cc-allow',
                '[data-testid="cookie-policy-manage-dialog-btn-accept-all"]',
                '.cookie-consent-accept-all',
                '[aria-label="Accept all cookies"]',
                '[aria-label="Accept All Cookies"]',
                '.js-accept-all-cookies',
                '#accept-all-cookies',
                '.accept-cookies-button',
                '#truste-consent-button',
                '.trustarc-agree-btn',
                '#didomi-notice-agree-button',
                '.didomi-components-button--color.didomi-button-highlight',
                '#consent_prompt_submit',
                '.fc-cta-consent',
                '.qc-cmp2-summary-buttons button[mode="primary"]',
                '.sp_choice_type_11',
                '#ez-accept-all',
                '.ncb2f',
            ];

            // Only cookie-specific phrases — generic words like "OK",
            // "Accept", "Allow", "Agree", "Got it" were clicking unrelated
            // confirmation/payment dialogs.
            const TEXT_PATTERNS = [
                /^accept all cookies$/i,
                /^allow all cookies$/i,
                /^accept all$/i,
                /^allow all$/i,
                /^accept all and continue$/i,
                /^accept & close$/i,
                /^accept and close$/i,
                /^agree & proceed$/i,
                /^agree and proceed$/i,
            ];

            // Containers that strongly suggest a cookie/consent dialog.
            // Text-pattern matching is scoped to buttons inside one of
            // these — that way "Accept all" inside an unrelated wizard
            // can't trigger us.
            const CONSENT_CONTAINER_HINTS = [
                'cookie', 'consent', 'gdpr', 'privacy', 'cmp',
                'onetrust', 'cookiebot', 'didomi', 'trustarc',
                'usercentrics', 'sourcepoint', 'quantcast',
            ];

            function isInsideConsentContainer(el) {
                let node = el;
                while (node && node !== document.body) {
                    const attrs = [
                        node.id || '',
                        node.className && node.className.toString ? node.className.toString() : '',
                        node.getAttribute && (node.getAttribute('aria-label') || ''),
                        node.getAttribute && (node.getAttribute('role') || ''),
                        node.getAttribute && (node.getAttribute('data-testid') || ''),
                    ].join(' ').toLowerCase();
                    if (CONSENT_CONTAINER_HINTS.some(h => attrs.indexOf(h) !== -1)) {
                        return true;
                    }
                    node = node.parentElement;
                }
                return false;
            }

            function tryDismiss() {
                for (const sel of SELECTORS) {
                    const el = document.querySelector(sel);
                    if (el && el.offsetParent !== null) {
                        el.click();
                        return true;
                    }
                }

                const buttons = document.querySelectorAll(
                    'button, a[role="button"], [role="button"], input[type="submit"], input[type="button"]'
                );
                for (const btn of buttons) {
                    const text = (btn.textContent || btn.value || '').trim();
                    if (!TEXT_PATTERNS.some(p => p.test(text))) continue;
                    if (!isInsideConsentContainer(btn)) continue;
                    const style = window.getComputedStyle(btn);
                    if (style.display !== 'none' && style.visibility !== 'hidden' && btn.offsetParent !== null) {
                        btn.click();
                        return true;
                    }
                }
                return false;
            }

            function run() {
                if (tryDismiss()) return;

                const observer = new MutationObserver(function(mutations, obs) {
                    if (tryDismiss()) {
                        obs.disconnect();
                    }
                });
                observer.observe(document.body || document.documentElement, {
                    childList: true,
                    subtree: true,
                });

                setTimeout(function() { observer.disconnect(); }, 15000);
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', function() {
                    setTimeout(run, 500);
                });
            } else {
                setTimeout(run, 500);
            }
        })();
        """
    }
}
