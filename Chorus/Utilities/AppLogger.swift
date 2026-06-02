import os

enum AppLogger {
    private static let subsystem = "com.nicojan.Chorus"

    static let general = Logger(subsystem: subsystem, category: "General")
    static let dataStore = Logger(subsystem: subsystem, category: "DataStore")
    static let webView = Logger(subsystem: subsystem, category: "WebView")
    static let notifications = Logger(subsystem: subsystem, category: "Notifications")
    static let favicon = Logger(subsystem: subsystem, category: "Favicon")
    static let badges = Logger(subsystem: subsystem, category: "Badges")
    static let ui = Logger(subsystem: subsystem, category: "UI")
}
