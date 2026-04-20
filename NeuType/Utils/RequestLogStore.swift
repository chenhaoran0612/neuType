import Foundation

enum RequestLogContext {
    @TaskLocal
    static var meetingID: UUID?
}

enum RequestLogKind: String, CaseIterable, Identifiable {
    case asr = "ASR"
    case llm = "LLM"
    case usage = "Key/Usage"

    var id: String { rawValue }
}

struct RequestLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let kind: RequestLogKind
    let meetingID: UUID?
    let message: String
}

@MainActor
final class RequestLogStore: ObservableObject {
    static let shared = RequestLogStore()

    @Published private(set) var entries: [RequestLogEntry] = []

    private init() {}

    nonisolated static func log(_ kind: RequestLogKind, _ message: String) {
        let meetingID = RequestLogContext.meetingID
        Task { @MainActor in
            RequestLogStore.shared.add(kind, message, meetingID: meetingID)
        }
    }

    func add(_ kind: RequestLogKind, _ message: String) {
        add(kind, message, meetingID: RequestLogContext.meetingID)
    }

    func add(_ kind: RequestLogKind, _ message: String, meetingID: UUID?) {
        let entry = RequestLogEntry(timestamp: Date(), kind: kind, meetingID: meetingID, message: message)
        entries.append(entry)
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
