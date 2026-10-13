import Foundation
import os

extension Logger {
    /// Logs a message that was assembled from plain `String` work.
    ///
    /// `os.Logger`'s string interpolation produces `OSLogMessage`, which cannot
    /// be concatenated with `+` and cannot be built in a loop. Any multi-part
    /// log line must therefore be assembled as a `String` first and handed to
    /// this method, which also keeps privacy explicit in one place.
    ///
    /// Everything DayPilot logs is its own diagnostics, never user content, so
    /// `public` is safe: a redacted capture log would be useless for debugging.
    func plain(_ message: String) {
        log("\(message, privacy: .public)")
    }
}
