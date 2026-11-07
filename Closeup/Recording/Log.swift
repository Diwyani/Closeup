import os

extension Logger {
    /// Recording pipeline messages. Read them in Xcode's console, or with:
    ///     log show --last 10m --predicate 'subsystem == "app.closeup.Closeup"'
    static let recording = Logger(subsystem: "app.closeup.Closeup", category: "recording")
}
