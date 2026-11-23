import os

/// Diagnostics go through os.Logger, never print/NSLog. Interpolated values keep the default (private) privacy, so they are
/// redacted in the unified log unless the machine is in development mode. Log constants, ids and codes: never session content.
enum Log {
    static let subsystem = "sg.gov.tech.grl.chippy"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotKeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let sound = Logger(subsystem: subsystem, category: "sound")
    static let jump = Logger(subsystem: subsystem, category: "jump")
    static let keepAwake = Logger(subsystem: subsystem, category: "keepawake")
}
