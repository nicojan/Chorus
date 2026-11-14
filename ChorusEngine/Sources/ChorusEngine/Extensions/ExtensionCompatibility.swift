import Foundation

/// Fills gaps between WebKit and Chrome that stop Chrome builds of
/// extensions, by adding one script to each package Chorus copied in.
///
/// 1. WebKit runs an extension's service worker on its process's main thread.
///    A worker's WebSocket is built by a bridge that hands the work to the main
///    thread and waits for it, so the worker waits on itself and the process
///    never runs another line, popups included. Bitwarden opens one to its
///    notifications server as soon as someone signs in: its sign-in spun
///    forever and its popup never opened again. In a service worker the script
///    swaps `WebSocket` for one that fails the way a refused connection does:
///    an `error` event, then `close` with code 1006. Bitwarden tries again a
///    few minutes later and syncs when its popup opens, so it loses only live
///    updates from its server.
/// 2. Chrome 134 has `Symbol.dispose` and `Symbol.asyncDispose`; WebKit has
///    neither. TypeScript's `using` throws without them, and Bitwarden uses it
///    to unlock and to decrypt the vault. The script defines both.
/// 3. Asked about a permission it does not know, such as Chrome's `privacy`,
///    WebKit's `permissions.contains` throws where Chrome answers false.
///    Bitwarden's popup asks on its start screen, and the throw left it
///    blank. The script answers false.
/// 4. WebKit takes "ISOLATED" and "MAIN" as a script's world but has no
///    `scripting.ExecutionWorld` to name them. Bitwarden reads it each time
///    it injects its fill scripts, so every injection failed. The script adds
///    it.
///
/// WebKit drops the JavaScript wrapper of an API object nothing refers to and
/// builds a new one on the next read, so the script holds every object it
/// changes; without that the additions vanished after a garbage collection.
///
/// 5. WebKit has no `chrome.offscreen`, the hidden page a Chrome extension
///    opens to do what a service worker cannot, such as copy text. Bitwarden
///    copies through one from its right-click items, and its fallback asked
///    the worker for a `document` it does not have. For an extension that
///    asks for `offscreen`, the script defines it: the page opens through a
///    marked `tabs.create` that `WebExtensionHost` turns into a hidden view,
///    and it answers a ping once it is listening.
///
/// 6. WebKit gives a service worker the user agent of whichever page in the
///    app last set one (`WebProcessPool::updateRemoteWorkerUserAgent`), not
///    the agent of the extension's own configuration. On macOS 26 the worker
///    came up with no browser named at all, which in Bitwarden's Chrome build
///    stops its background from starting, and a service with a custom agent
///    could hand it that agent instead. In the service worker the script pins
///    `navigator.userAgent` and `appVersion` to what extension pages report.
///
/// 7. WebKit has no `runtime.onUpdateAvailable`, in the service worker or in
///    extension pages. Proton Pass listens to it as its background starts, so
///    the call threw and the background stopped. Chorus updates extensions
///    itself, so from an extension's side an update never waits: the script
///    adds an event that takes listeners and never fires. It goes in the
///    service worker and extension pages, where Chrome has it, and not in
///    content scripts, where Chrome does not.
///
/// The script loads first in the service worker (through a new entry file),
/// in every HTML page, in background scripts and ahead of each content script.
/// Safari extensions inside an app are signed and left alone.
enum ExtensionCompatibility {
    /// The tail of an extension page's user agent. Chrome 134 is the oldest
    /// that Bitwarden's Chrome build accepts.
    static let chromeApplicationName = "Chrome/134.0.0.0 Safari/605.1.15"
    /// What an extension's service worker reports as its user agent: WebKit's
    /// frozen Mac agent with the same tail.
    static let backgroundUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + chromeApplicationName
    static let scriptFile = "__chorus_compat.js"
    static let workerFile = "__chorus_service_worker.js"
    private static let scriptTag = "<script src=\"/\(scriptFile)\"></script>"

    /// Adds the script to the package at `root`. Runs at every load: it
    /// refreshes the script and leaves anything it already changed as it is.
    static func apply(to root: URL) throws {
        guard var manifest = WebExtensionLibrary.readManifest(at: root) else { return }
        try Data(script.utf8).write(to: root.appending(path: scriptFile), options: .atomic)

        var changed = false
        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, !worker.isEmpty, worker != workerFile {
                let isModule = (background["type"] as? String) == "module"
                try Data(entryScript(loading: worker, isModule: isModule).utf8)
                    .write(to: root.appending(path: workerFile), options: .atomic)
                background["service_worker"] = workerFile
                changed = true
            }
            if let scripts = background["scripts"] as? [String], let first = prepended(scripts) {
                background["scripts"] = first
                changed = true
            }
            manifest["background"] = background
        }
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            let updated = entries.map { entry -> [String: Any] in
                guard let scripts = entry["js"] as? [String], let first = prepended(scripts) else { return entry }
                return entry.merging(["js": first]) { $1 }
            }
            if !updated.elementsEqual(entries, by: { ($0["js"] as? [String]) == ($1["js"] as? [String]) }) {
                manifest["content_scripts"] = updated
                changed = true
            }
        }
        if changed {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: root.appending(path: "manifest.json"), options: .atomic)
        }
        try addScriptToPages(under: root)
    }

    /// `scripts` with the compatibility script first, or nil when it already
    /// is or there is nothing to run.
    private static func prepended(_ scripts: [String]) -> [String]? {
        guard !scripts.isEmpty, scripts.first != scriptFile else { return nil }
        return [scriptFile] + scripts
    }

    /// The new service worker: the compatibility script, then the extension's.
    static func entryScript(loading worker: String, isModule: Bool) -> String {
        let path = worker.hasPrefix("/") ? worker : "/" + worker
        let first = quoted("/" + scriptFile)
        let second = quoted(path)
        if isModule {
            return "import \(first);\nimport \(second);\n"
        }
        return "importScripts(\(first), \(second));\n"
    }

    /// Puts the script tag at the top of every HTML page's head.
    private static func addScriptToPages(under root: URL) throws {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in walker where ["html", "htm"].contains(file.pathExtension.lowercased()) {
            guard let page = try? String(contentsOf: file, encoding: .utf8),
                  let updated = withScriptTag(page) else { continue }
            try Data(updated.utf8).write(to: file, options: .atomic)
        }
    }

    /// `page` with the script tag first inside `<head>` (or first of all when
    /// there is no head), or nil when it already has the tag.
    static func withScriptTag(_ page: String) -> String? {
        guard !page.contains(scriptTag) else { return nil }
        if let head = page.range(of: "<head\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return page.replacingCharacters(in: head, with: page[head] + scriptTag)
        }
        if let html = page.range(of: "<html\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return page.replacingCharacters(in: html, with: page[html] + "<head>" + scriptTag + "</head>")
        }
        return scriptTag + page
    }

    /// A JavaScript string literal: JSON's quoting is valid JavaScript.
    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static let script = scriptTemplate.replacingOccurrences(of: "__CHORUS_BACKGROUND_AGENT__", with: quoted(backgroundUserAgent))

    private static let scriptTemplate = """
    // Added by Chorus to fill gaps between WebKit and Chrome.
    (() => {
      // Chrome 134 has these and TypeScript's `using` needs them.
      for (const name of ["dispose", "asyncDispose"]) {
        if (typeof Symbol[name] !== "symbol") {
          Object.defineProperty(Symbol, name, { value: Symbol("Symbol." + name) });
        }
      }

      // WebKit drops the wrapper of an API object nothing refers to and builds
      // a new one on the next read, without what was added below. Holding
      // each patched object keeps its wrapper, and the additions, alive.
      // Two content script entries run this twice in one world; once is enough.
      if (globalThis.__chorusCompatibilityObjects) return;
      const held = [];
      Object.defineProperty(globalThis, "__chorusCompatibilityObjects", { value: held });

      // WebKit takes "ISOLATED" and "MAIN" as a script's world but has no
      // `scripting.ExecutionWorld` to name them, which Chrome builds read.
      for (const api of [globalThis.chrome, globalThis.browser]) {
        const scripting = api && api.scripting;
        if (!scripting || scripting.ExecutionWorld) continue;
        held.push(api, scripting);
        try {
          Object.defineProperty(scripting, "ExecutionWorld", {
            value: Object.freeze({ ISOLATED: "ISOLATED", MAIN: "MAIN" }), configurable: true
          });
        } catch (error) {}
      }

      // WebKit throws when asked about a permission it does not know, such as
      // Chrome's "privacy"; Chrome answers false. Answer false here too.
      const wrapped = new WeakSet();
      for (const api of [globalThis.chrome, globalThis.browser]) {
        const permissions = api && api.permissions;
        if (!permissions || typeof permissions.contains !== "function" || wrapped.has(permissions)) continue;
        wrapped.add(permissions);
        held.push(api, permissions);
        const contains = permissions.contains.bind(permissions);
        const answer = function (details, callback) {
          try {
            return contains(details, callback);
          } catch (error) {
            if (!/is not a valid permission/.test(String(error && error.message))) throw error;
            if (typeof callback === "function") {
              setTimeout(() => callback(false), 0);
              return undefined;
            }
            return Promise.resolve(false);
          }
        };
        try {
          Object.defineProperty(permissions, "contains", { value: answer, writable: true, configurable: true });
        } catch (error) {}
      }

      // WebKit has no `runtime.onUpdateAvailable`. Chorus updates extensions
      // itself, so this event takes listeners and never fires. Chrome has it
      // in the service worker and extension pages, not in content scripts.
      const isExtensionContext = (api) => {
        try {
          return typeof location !== "undefined" && String(location.href).startsWith(api.runtime.getURL("/"));
        } catch (error) {
          return false;
        }
      };
      const updateListeners = new Set();
      const onUpdateAvailable = Object.freeze({
        addListener(listener) { updateListeners.add(listener); },
        removeListener(listener) { updateListeners.delete(listener); },
        hasListener(listener) { return updateListeners.has(listener); },
        hasListeners() { return updateListeners.size > 0; }
      });
      for (const api of [globalThis.chrome, globalThis.browser]) {
        const runtime = api && api.runtime;
        if (!runtime || runtime.onUpdateAvailable || typeof runtime.getURL !== "function" || !isExtensionContext(api)) continue;
        held.push(api, runtime);
        try {
          Object.defineProperty(runtime, "onUpdateAvailable", { value: onUpdateAvailable, configurable: true, enumerable: true });
        } catch (error) {}
      }

      // WebKit has no `chrome.offscreen`. Chorus opens the page in a hidden
      // view when asked for a tab with this marker, and the page answers a
      // ping once it is up.
      const offscreenMarker = "chorus-offscreen";
      const runtime = globalThis.chrome && globalThis.chrome.runtime;
      const isWorker = typeof ServiceWorkerGlobalScope !== "undefined" && self instanceof ServiceWorkerGlobalScope;
      if (!isWorker && runtime && runtime.onMessage && typeof location !== "undefined"
          && location.hash === "#" + offscreenMarker && location.origin === new URL(runtime.getURL("/")).origin) {
        runtime.onMessage.addListener((message, sender, sendResponse) => {
          if (message && message.__chorusOffscreen === "ping") sendResponse(true);
        });
      }
      const manifest = runtime && typeof runtime.getManifest === "function" ? runtime.getManifest() : null;
      const wantsOffscreen = isWorker && manifest && (manifest.permissions || []).includes("offscreen");
      for (const api of wantsOffscreen ? [globalThis.chrome, globalThis.browser] : []) {
        if (!api || api.offscreen || !api.runtime || !api.tabs) continue;
        const ping = () => api.runtime.sendMessage({ __chorusOffscreen: "ping" }).then((answer) => answer === true, () => false);
        const offscreen = {
          Reason: Object.freeze(Object.fromEntries([
            "TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA",
            "DISPLAY_MEDIA", "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"
          ].map((reason) => [reason, reason]))),
          async hasDocument() { return ping(); },
          async createDocument(parameters) {
            if (await ping()) throw new Error("Only a single offscreen document may be created.");
            const url = new URL(parameters.url, api.runtime.getURL("/"));
            url.hash = offscreenMarker;
            try { await api.tabs.create({ url: url.href, active: false }); } catch (error) {}
            for (let tries = 0; tries < 100; tries++) {
              if (await ping()) return;
              await new Promise((resolve) => setTimeout(resolve, 100));
            }
            throw new Error("The offscreen document did not load.");
          },
          // Chorus keeps the page until the extension stops, so a close and
          // the create that follows it cannot race.
          async closeDocument() {}
        };
        held.push(api);
        try {
          Object.defineProperty(api, "offscreen", { value: offscreen, configurable: true });
        } catch (error) {}
      }

      // WebKit gives a service worker the agent of the last page in the app
      // that set one, not the extension's. Report what extension pages do.
      if (isWorker) {
        const agent = __CHORUS_BACKGROUND_AGENT__;
        const navigatorPrototype = Object.getPrototypeOf(self.navigator);
        try {
          Object.defineProperty(navigatorPrototype, "userAgent", { get: () => agent, configurable: true, enumerable: true });
          Object.defineProperty(navigatorPrototype, "appVersion", { get: () => agent.slice("Mozilla/".length), configurable: true, enumerable: true });
        } catch (error) {}
      }

      // WebKit runs an extension's service worker on its process's main thread,
      // where opening a WebSocket waits on that same thread for good and stops
      // every page of the extension. This WebSocket fails the way a refused
      // connection does instead.
      if (!isWorker) return;
      const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
      class WebSocket extends EventTarget {
        constructor(url, protocols) {
          super();
          const target = new URL(url, self.location.href);
          if (!["ws:", "wss:", "http:", "https:"].includes(target.protocol) || target.hash) {
            throw new DOMException("The URL '" + url + "' is not valid for a WebSocket.", "SyntaxError");
          }
          if (target.protocol === "http:") target.protocol = "ws:";
          if (target.protocol === "https:") target.protocol = "wss:";
          this.url = target.href;
          this.readyState = states.CONNECTING;
          this.protocol = "";
          this.extensions = "";
          this.bufferedAmount = 0;
          this.binaryType = "blob";
          this.onopen = null;
          this.onmessage = null;
          this.onerror = null;
          this.onclose = null;
          setTimeout(() => this._fail(), 0);
        }
        _fail() {
          if (this.readyState === states.CLOSED) return;
          this.readyState = states.CLOSED;
          this._emit(new Event("error"));
          this._emit(new CloseEvent("close", { code: 1006, reason: "", wasClean: false }));
        }
        _emit(event) {
          const handler = this["on" + event.type];
          if (typeof handler === "function") handler.call(this, event);
          this.dispatchEvent(event);
        }
        send() {
          if (this.readyState === states.CONNECTING) {
            throw new DOMException("The WebSocket is still connecting.", "InvalidStateError");
          }
        }
        close() {
          if (this.readyState === states.CLOSED) return;
          this.readyState = states.CLOSING;
          setTimeout(() => this._fail(), 0);
        }
      }
      for (const [name, value] of Object.entries(states)) {
        Object.defineProperty(WebSocket, name, { value });
        Object.defineProperty(WebSocket.prototype, name, { value });
      }
      Object.defineProperty(self, "WebSocket", { value: WebSocket, writable: true, configurable: true });
    })();

    """
}
