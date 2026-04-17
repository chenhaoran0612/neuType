import Foundation
import OSLog

enum MeetingLog {
    private static let logger = Logger(subsystem: "ai.neuxnet.neutype", category: "meeting")

    static func info(_ message: String) {
        RequestLogStore.log(.usage, "Meeting: \(message)")
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        RequestLogStore.log(.usage, "Meeting Error: \(message)")
        logger.error("\(message, privacy: .public)")
    }
}
