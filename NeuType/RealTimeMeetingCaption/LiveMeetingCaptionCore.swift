import CryptoKit
import Foundation

struct LiveMeetingCaptionCredentials: Equatable, Sendable {
    var subscriptionKey: String
    var region: String

    init(subscriptionKey: String, region: String) {
        self.subscriptionKey = subscriptionKey
        self.region = region
    }

    init(appKey: String, appSecret: String) {
        self.init(subscriptionKey: appKey, region: appSecret)
    }

    var trimmedSubscriptionKey: String {
        subscriptionKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedRegion: String {
        region.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAppKey: String { trimmedSubscriptionKey }
    var trimmedAppSecret: String { trimmedRegion }

    var isConfigured: Bool {
        !trimmedSubscriptionKey.isEmpty && !trimmedRegion.isEmpty
    }
}

struct LiveMeetingCaptionSessionConfiguration: Equatable, Sendable {
    let credentials: LiveMeetingCaptionCredentials
    let targetLanguage: RealTimeMeetingCaptionLanguage
    let subtitleRetentionCount: Int
    let chunkDurationMS: Int
}

protocol LiveMeetingCaptionPreferencesProviding: AnyObject, Sendable {
    var targetLanguage: RealTimeMeetingCaptionLanguage { get set }
    var subtitleRetentionCount: Int { get set }
    var chunkDurationMS: Int { get set }
}

protocol LiveMeetingCaptionProviding: Sendable {
    func start(configuration: LiveMeetingCaptionSessionConfiguration) async throws -> AsyncStream<RealTimeMeetingCaptionEvent>
    func sendAudioFrame(_ data: Data) async throws
    func stop() async
}

protocol LiveMeetingAudioCapturing: Sendable {
    func start(frameHandler: @escaping @Sendable (Data) -> Void) async throws
    func stop() async
}

enum LiveMeetingCaptionError: LocalizedError, Equatable {
    case missingCredentials
    case invalidURL
    case providerNotStarted
    case audioCaptureFailed(String)
    case sendFailed(String)
    case networkFailed(String)
    case authenticationFailed(String)
    case serviceError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "请先在设置中填写 Azure Speech Key 和 Region。"
        case .invalidURL:
            return "无法生成有道同传请求地址。"
        case .providerNotStarted:
            return "实时字幕会话尚未启动。"
        case .audioCaptureFailed(let message):
            return "音频采集失败：\(message)"
        case .sendFailed(let message):
            return "音频发送失败：\(message)"
        case .networkFailed(let message):
            return "实时字幕连接异常：\(message)"
        case .authenticationFailed(let message):
            return message
        case .serviceError(let message):
            return message
        }
    }
}

enum YoudaoLiveCaptionSigner {
    static func sign(
        appKey: String,
        salt: String,
        currentTime: String,
        appSecret: String
    ) -> String {
        let normalized = [
            appKey.trimmingCharacters(in: .whitespacesAndNewlines),
            salt.trimmingCharacters(in: .whitespacesAndNewlines),
            currentTime.trimmingCharacters(in: .whitespacesAndNewlines),
            appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .joined()

        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct YoudaoLiveCaptionURLBuilder {
    private let endpoint = URL(string: "wss://openapi.youdao.com/stream-audio/stream-si")

    func makeURL(
        credentials: LiveMeetingCaptionCredentials,
        targetLanguage: RealTimeMeetingCaptionLanguage,
        salt: String,
        currentTime: String
    ) throws -> URL {
        let trimmedAppKey = credentials.trimmedAppKey
        let trimmedAppSecret = credentials.trimmedAppSecret
        guard !trimmedAppKey.isEmpty, !trimmedAppSecret.isEmpty, let endpoint else {
            throw LiveMeetingCaptionError.invalidURL
        }

        let sign = YoudaoLiveCaptionSigner.sign(
            appKey: trimmedAppKey,
            salt: salt,
            currentTime: currentTime,
            appSecret: trimmedAppSecret
        )

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "appKey", value: trimmedAppKey),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "curtime", value: currentTime),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: targetLanguage.youdaoLanguageCode),
            URLQueryItem(name: "speakerRequired", value: "false"),
            URLQueryItem(name: "ttsRequired", value: "false")
        ]

        guard let url = components?.url else {
            throw LiveMeetingCaptionError.invalidURL
        }
        return url
    }
}

struct YoudaoLiveCaptionResponseParser {
    struct ParsedMessage {
        let event: RealTimeMeetingCaptionEvent
        let shouldFinish: Bool
    }

    static func parse(_ text: String) -> RealTimeMeetingCaptionEvent? {
        parseMessage(text)?.event
    }

    static func parseMessage(
        _ text: String,
        targetLanguage: RealTimeMeetingCaptionLanguage? = nil
    ) -> ParsedMessage? {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let payload = object as? [String: Any]
        else {
            return nil
        }

        let errorCode = stringValue(payload["errorCode"])
        let action = stringValue(payload["action"])
        let isEnd = boolValue(payload["isEnd"]) ?? false
        let rawMessage = stringValue(payload["msg"])

        if let errorCode, errorCode != "0" {
            return ParsedMessage(
                event: .error(message: friendlyErrorMessage(code: errorCode, message: rawMessage)),
                shouldFinish: true
            )
        }

        if action == "started" {
            return ParsedMessage(event: .started, shouldFinish: false)
        }

        guard let resultList = payload["result"] as? [[String: Any]], let firstResult = resultList.first else {
            return nil
        }

        let sentence = nestedString(firstResult, keyPath: ["st", "sentence"]) ?? ""
        let translation = nestedString(firstResult, keyPath: ["st", "translation"]) ?? ""
        let bg = nestedInt(firstResult, keyPath: ["st", "bg"])
        let ed = nestedInt(firstResult, keyPath: ["st", "ed"])
        let type = nestedInt(firstResult, keyPath: ["st", "type"])
        let partial = nestedBool(firstResult, keyPath: ["st", "partial"])
        let segId = nestedInt(firstResult, keyPath: ["segId"]) ?? 0
        let isFinal = partial.map { !$0 } ?? (type == 0)
        let detectedTargetLanguage = targetLanguage
        let targetLabel = detectedTargetLanguage?.displayName ?? "unknown"
        let displayText = translation.isEmpty ? sentence : translation

        RequestLogStore.log(
            .usage,
            "Live captions parsed segId=\(segId) final=\(isFinal) target=\(targetLabel) source=\(sentence) translation=\(translation) display=\(displayText)"
        )

        let segment = RealTimeMeetingCaptionSegment(
            id: segId,
            sourceText: sentence,
            translatedText: translation,
            isFinal: isFinal,
            targetLanguage: targetLanguage,
            startMilliseconds: bg,
            endMilliseconds: ed,
            lastUpdatedAt: Date()
        )

        return ParsedMessage(
            event: .segment(segment),
            shouldFinish: isEnd
        )
    }

    private static func friendlyErrorMessage(code: String, message: String?) -> String {
        switch code {
        case "108":
            return "有道 App Key 无效，请检查是否填写了正确的应用 ID。"
        case "110":
            return "有道返回 110：当前应用 ID 没有权限访问此服务。请在有道控制台给这个应用开通“大模型同声传译”，并确认 App Key 和 App Secret 属于同一个应用。"
        case "112":
            return "有道请求的服务不存在，请检查当前应用是否支持同声传译接口。"
        case "202":
            return "有道签名校验失败，请检查 App Key 和 App Secret。"
        case "206":
            return "有道请求时间戳无效，请检查设备时间。"
        case "207":
            return "有道请求已过期，请重试。"
        case "901210":
            return "有道同传连接空闲超时。"
        case "901201":
            return "有道识别连接失败。"
        case "901202", "901203":
            return "有道识别连接中断。"
        default:
            if let message, !message.isEmpty {
                return "有道同传返回错误（\(code)）：\(message)"
            }
            return "有道同传返回错误：\(code)"
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return string.lowercased() == "true"
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func nestedString(_ object: [String: Any], keyPath: [String]) -> String? {
        nestedValue(object, keyPath: keyPath).flatMap(stringValue)
    }

    private static func nestedInt(_ object: [String: Any], keyPath: [String]) -> Int? {
        nestedValue(object, keyPath: keyPath).flatMap(intValue)
    }

    private static func nestedBool(_ object: [String: Any], keyPath: [String]) -> Bool? {
        nestedValue(object, keyPath: keyPath).flatMap(boolValue)
    }

    private static func nestedValue(_ object: [String: Any], keyPath: [String]) -> Any? {
        var current: Any? = object
        for key in keyPath {
            guard let dictionary = current as? [String: Any] else {
                return nil
            }
            current = dictionary[key]
        }
        return current
    }
}

extension AppPreferences: LiveMeetingCaptionPreferencesProviding {
    var targetLanguage: RealTimeMeetingCaptionLanguage {
        get { RealTimeMeetingCaptionLanguage.language(from: liveMeetingCaptionTargetLanguage) }
        set { liveMeetingCaptionTargetLanguage = newValue.rawValue }
    }

    var subtitleRetentionCount: Int {
        get { liveMeetingCaptionSubtitleRetentionCount }
        set { liveMeetingCaptionSubtitleRetentionCount = newValue }
    }

    var chunkDurationMS: Int {
        get { liveMeetingCaptionChunkDurationMS }
        set { liveMeetingCaptionChunkDurationMS = newValue }
    }
}
