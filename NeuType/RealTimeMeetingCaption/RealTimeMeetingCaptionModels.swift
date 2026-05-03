import Foundation

struct RealTimeMeetingCaptionSegment: Identifiable, Equatable, Sendable {
    let id: Int
    var sourceText: String
    var translatedText: String
    var isFinal: Bool
    var targetLanguage: RealTimeMeetingCaptionLanguage?
    var startMilliseconds: Int?
    var endMilliseconds: Int?
    var lastUpdatedAt: Date

    init(
        id: Int,
        sourceText: String,
        translatedText: String,
        isFinal: Bool,
        targetLanguage: RealTimeMeetingCaptionLanguage? = nil,
        startMilliseconds: Int? = nil,
        endMilliseconds: Int? = nil,
        lastUpdatedAt: Date = .init()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.isFinal = isFinal
        self.targetLanguage = targetLanguage
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.lastUpdatedAt = lastUpdatedAt
    }
}

struct RealTimeMeetingCaptionLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

enum RealTimeMeetingCaptionState: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case stopping
    case failed(message: String)
}

enum RealTimeMeetingCaptionEvent: Equatable, Sendable {
    case started
    case segment(RealTimeMeetingCaptionSegment)
    case error(message: String)
}
