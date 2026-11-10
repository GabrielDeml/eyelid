import os

/// `log stream --predicate 'subsystem == "com.gdeml.Insomnia.helper"'` (docs/DESIGN.md "Verify").
enum HelperLog {
    static let subsystem = "com.gdeml.Insomnia.helper"
    static let main = Logger(subsystem: subsystem, category: "main")
    static let xpc = Logger(subsystem: subsystem, category: "xpc")
    static let flag = Logger(subsystem: subsystem, category: "flag")
    static let backstop = Logger(subsystem: subsystem, category: "backstop")
}
