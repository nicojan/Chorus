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

            const TEXT_PATTERNS = [
                /^accept all$/i,
                /^accept all cookies$/i,
                /^allow all$/i,
                /^allow all cookies$/i,
                /^agree$/i,
                /^agree & proceed$/i,
                /^i agree$/i,
                /^got it$/i,
                /^ok$/i,
                /^accept$/i,
                /^allow$/i,
                /^consent$/i,
                /^accept & close$/i,
                /^accept and close$/i,
            ];

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
                    if (TEXT_PATTERNS.some(p => p.test(text))) {
                        const style = window.getComputedStyle(btn);
                        if (style.display !== 'none' && style.visibility !== 'hidden' && btn.offsetParent !== null) {
                            btn.click();
                            return true;
                        }
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
