import os

public enum AppLogger {
    private static let subsystem = "com.nicojan.Chorus"

    public static let general = Logger(subsystem: subsystem, category: "General")
    public static let dataStore = Logger(subsystem: subsystem, category: "DataStore")
    public static let webView = Logger(subsystem: subsystem, category: "WebView")
    public static let notifications = Logger(subsystem: subsystem, category: "Notifications")
    public static let favicon = Logger(subsystem: subsystem, category: "Favicon")
    public static let badges = Logger(subsystem: subsystem, category: "Badges")
    public static let ui = Logger(subsystem: subsystem, category: "UI")
}
