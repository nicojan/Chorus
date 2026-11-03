import WebKit

/// One thing a page did with IndexedDB that could explain lost data: the
/// databases it found at load, a schema upgrade, an open that failed or was
/// blocked, a database it deleted, a write transaction that aborted with an
/// error, or a page error that mentions storage.
///
/// WhatsApp Web shows "A database error occurred … relink" and wipes its own
/// databases, and WebKit logs nothing about why. These events are the page's
/// side of that story.
public struct PageStorageEvent: Codable, Equatable, Sendable {
    /// `inventory`, `upgrade`, `openError`, `blocked`, `delete`, `txAbort` or
    /// `pageError`.
    public var kind: String
    /// The database, when there is one.
    public var database: String?
    /// For `upgrade`.
    public var oldVersion: Int?
    public var newVersion: Int?
    /// The DOMException name, such as `QuotaExceededError` or `UnknownError`.
    public var errorName: String?
    /// The error message, the page error text, the inventory list, or the
    /// start of the stack that called `deleteDatabase`.
    public var detail: String?
    /// The page's host when the event fired.
    public var host: String?

    public init(kind: String, database: String? = nil, oldVersion: Int? = nil, newVersion: Int? = nil, errorName: String? = nil, detail: String? = nil, host: String? = nil) {
        self.kind = kind
        self.database = database
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.errorName = errorName
        self.detail = detail
        self.host = host
    }

    static let kinds: Set<String> = ["inventory", "upgrade", "openError", "blocked", "delete", "txAbort", "pageError"]

    /// The longest `detail` and `database` kept. A page writes both.
    static let maxDetailLength = 1000
    static let maxNameLength = 200

    /// Reads a message body from the watch script. Nil for anything that is not
    /// a known event; text fields are cut to length.
    static func decode(_ body: Any) -> PageStorageEvent? {
        guard let text = body as? String,
              var event = try? JSONDecoder().decode(PageStorageEvent.self, from: Data(text.utf8)),
              kinds.contains(event.kind)
        else { return nil }
        event.database = event.database.map { String($0.prefix(maxNameLength)) }
        event.errorName = event.errorName.map { String($0.prefix(maxNameLength)) }
        event.detail = event.detail.map { String($0.prefix(maxDetailLength)) }
        event.host = nil
        return event
    }
}

extension UserScriptManager {
    static let storageEventHandlerName = "chorusStorageEvent"

    /// Watches the page's IndexedDB use and posts a `PageStorageEvent` for each
    /// thing worth keeping (see that type). Main frame only. It wraps the same
    /// `IDBFactory` methods as the write tracker; the two chain.
    ///
    /// It sends at most 200 events a page load, so a page stuck in an error
    /// loop cannot fill the log.
    static func makeStorageWatchScript() -> String {
        return """
        (function() {
            try {
                if (!window.IDBFactory || !window.IDBDatabase || window.__chorusStorageWatch) { return; }
                Object.defineProperty(window, '__chorusStorageWatch', { value: true, configurable: false, enumerable: false });
                var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(storageEventHandlerName);
                if (!handler) { return; }
                var post = handler.postMessage.bind(handler);
                var stringify = JSON.stringify;
                var sent = 0;
                function send(event) {
                    if (sent >= 200) { return; }
                    sent++;
                    try { post(stringify(event)); } catch (e) {}
                }
                function text(value) {
                    try { return String(value).slice(0, 1000); } catch (e) { return ''; }
                }
                function errorFields(event, error) {
                    if (error) {
                        event.errorName = text(error.name);
                        event.detail = text(error.message);
                    }
                    return event;
                }
                var mentionsStorage = /indexeddb|idb|database|quota|storage/i;

                var factory = IDBFactory.prototype;
                var open = factory.open;
                factory.open = function(name, version) {
                    var request = open.apply(this, arguments);
                    try {
                        request.addEventListener('upgradeneeded', function(e) {
                            send({ kind: 'upgrade', database: text(name), oldVersion: e.oldVersion, newVersion: e.newVersion });
                        });
                        request.addEventListener('error', function() {
                            send(errorFields({ kind: 'openError', database: text(name) }, request.error));
                        });
                        request.addEventListener('blocked', function() {
                            send({ kind: 'blocked', database: text(name), detail: 'open' });
                        });
                    } catch (e) {}
                    return request;
                };
                var deleteDatabase = factory.deleteDatabase;
                factory.deleteDatabase = function(name) {
                    var stack = '';
                    try { stack = new Error().stack.split('\\n').slice(1, 6).join('\\n'); } catch (e) {}
                    send({ kind: 'delete', database: text(name), detail: text(stack) });
                    var request = deleteDatabase.apply(this, arguments);
                    try {
                        request.addEventListener('blocked', function() {
                            send({ kind: 'blocked', database: text(name), detail: 'delete' });
                        });
                    } catch (e) {}
                    return request;
                };

                var transaction = IDBDatabase.prototype.transaction;
                IDBDatabase.prototype.transaction = function(names, mode) {
                    var tx = transaction.apply(this, arguments);
                    try {
                        var db = this;
                        tx.addEventListener('abort', function() {
                            // A transaction the page aborted itself has no error.
                            if (tx.error) {
                                send(errorFields({ kind: 'txAbort', database: text(db.name) }, tx.error));
                            }
                        });
                    } catch (e) {}
                    return tx;
                };

                function pageError(message) {
                    var line = text(message);
                    if (mentionsStorage.test(line)) { send({ kind: 'pageError', detail: line }); }
                }
                window.addEventListener('error', function(e) {
                    pageError((e.error && e.error.name ? e.error.name + ': ' : '') + e.message);
                });
                window.addEventListener('unhandledrejection', function(e) {
                    var reason = e.reason;
                    pageError(reason && reason.name ? reason.name + ': ' + reason.message : reason);
                });
                ['error', 'warn'].forEach(function(level) {
                    var original = console[level];
                    if (typeof original !== 'function') { return; }
                    console[level] = function() {
                        try {
                            var parts = [];
                            for (var i = 0; i < arguments.length && i < 5; i++) {
                                var a = arguments[i];
                                parts.push(a && a.name && a.message ? a.name + ': ' + a.message : text(a));
                            }
                            pageError(level + ': ' + parts.join(' '));
                        } catch (e) {}
                        return original.apply(this, arguments);
                    };
                });

                if (typeof indexedDB.databases === 'function') {
                    indexedDB.databases().then(function(list) {
                        var names = list.map(function(d) { return d.name + '@' + d.version; }).sort();
                        send({ kind: 'inventory', detail: names.length + ': ' + names.join(', ') });
                    }, function(error) {
                        send(errorFields({ kind: 'inventory' }, error));
                    });
                }
            } catch (e) {}
        })();
        """
    }
}

/// Takes the watch script's events from the main frame and hands them to
/// `UserScriptManager.onStorageEvent` with the service they came from.
final class StorageEventHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    let serviceID: UUID
    let deliver: @Sendable (UUID, PageStorageEvent) -> Void

    /// At most this many events from one web view in its life, on top of the
    /// script's own limit per load: a page that reloads in a loop stops here.
    static let lifetimeLimit = 1000
    private var delivered = 0

    init(serviceID: UUID, deliver: @escaping @Sendable (UUID, PageStorageEvent) -> Void) {
        self.serviceID = serviceID
        self.deliver = deliver
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == UserScriptManager.storageEventHandlerName,
              message.frameInfo.isMainFrame,
              delivered < Self.lifetimeLimit,
              var event = PageStorageEvent.decode(message.body)
        else { return }
        delivered += 1
        event.host = message.webView?.url?.host
        deliver(serviceID, event)
    }
}
