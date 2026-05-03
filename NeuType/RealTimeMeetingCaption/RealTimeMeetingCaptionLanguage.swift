import Foundation

enum RealTimeMeetingCaptionLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case chineseSimplified
    case english
    case arabic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chineseSimplified:
            return "中文（简体）"
        case .english:
            return "英文"
        case .arabic:
            return "阿语"
        }
    }

    var youdaoLanguageCode: String {
        switch self {
        case .chineseSimplified:
            return "zh-CHS"
        case .english:
            return "en"
        case .arabic:
            return "ar"
        }
    }

    var azureTargetLanguageCode: String {
        switch self {
        case .chineseSimplified:
            return "zh-Hans"
        case .english:
            return "en"
        case .arabic:
            return "ar"
        }
    }

    var azureSourceLanguageCode: String {
        switch self {
        case .chineseSimplified:
            return "zh-CN"
        case .english:
            return "en-US"
        case .arabic:
            return "ar-SA"
        }
    }

    static var azureAutoDetectSourceLanguageCodes: [String] {
        [
            "zh-CN",
            "en-US",
            "ar-SA",
            "ar-EG",
            "ar-AE"
        ]
    }

    static func language(from storedValue: String) -> Self {
        Self(rawValue: storedValue) ?? .english
    }
}
