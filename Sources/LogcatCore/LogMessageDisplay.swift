import Foundation

public enum LogMessageDisplay {
    // Recognize the logger's leading HH:mm:ss.SSS[thread] prefix only.
    // Bare timestamps and dates inside the actual message remain untouched.
    private static let loggerPrefix = try! NSRegularExpression(pattern: #"^[\t ]*(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d\.\d{3,6}\[\d+\][\t ]+(?=\S)"#)

    public static func clean(_ message: String) -> String {
        guard let prefix = loggerPrefix.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return message }
        return (message as NSString).substring(from: NSMaxRange(prefix.range))
    }
}

public extension LogEntry {
    var displayMessage: String { LogMessageDisplay.clean(message) }
}
