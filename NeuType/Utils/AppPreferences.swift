import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences: @unchecked Sendable {
    static let shared = AppPreferences()
    private init() {
        sanitizeMeetingSummaryBaseURL()
    }
    
    @UserDefault(key: "whisperLanguage", defaultValue: "auto")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: true)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool

    @UserDefault(key: "removeDisfluency", defaultValue: true)
    var removeDisfluency: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "leftControl")
    var modifierOnlyHotkey: String
    
    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool
    
    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    @UserDefault(key: "deepInfraAPIKey", defaultValue: "")
    var deepInfraAPIKey: String

    @UserDefault(key: "asrAPIBaseURL", defaultValue: "https://api.groq.com/openai/v1")
    var asrAPIBaseURL: String

    @UserDefault(key: "asrAPIKey", defaultValue: "")
    var asrAPIKey: String

    @UserDefault(key: "asrModel", defaultValue: "whisper-large-v3")
    var asrModel: String

    @UserDefault(key: "llmAPIBaseURL", defaultValue: "https://api.groq.com/openai/v1")
    var llmAPIBaseURL: String

    @UserDefault(key: "llmAPIKey", defaultValue: "")
    var llmAPIKey: String

    @UserDefault(key: "llmModel", defaultValue: "openai/gpt-oss-20b")
    var llmModel: String

    @UserDefault(key: "meetingVibeVoiceBaseURL", defaultValue: "https://meeting-transcription.neuxnet.com")
    var meetingVibeVoiceBaseURL: String

    @UserDefault(key: "meetingVibeVoiceAPIPrefix", defaultValue: "")
    var meetingVibeVoiceAPIPrefix: String

    @UserDefault(key: "meetingVibeVoiceAPIKey", defaultValue: "")
    var meetingVibeVoiceAPIKey: String

    @UserDefault(key: "meetingVibeVoiceContextInfo", defaultValue: "")
    var meetingVibeVoiceContextInfo: String

    @UserDefault(key: "meetingVibeVoiceMaxNewTokens", defaultValue: 8192)
    var meetingVibeVoiceMaxNewTokens: Int

    @UserDefault(key: "meetingVibeVoiceTemperature", defaultValue: 0.0)
    var meetingVibeVoiceTemperature: Double

    @UserDefault(key: "meetingVibeVoiceTopP", defaultValue: 1.0)
    var meetingVibeVoiceTopP: Double

    @UserDefault(key: "meetingVibeVoiceDoSample", defaultValue: false)
    var meetingVibeVoiceDoSample: Bool

    @UserDefault(key: "meetingVibeVoiceRepetitionPenalty", defaultValue: 1.0)
    var meetingVibeVoiceRepetitionPenalty: Double

    @UserDefault(key: "meetingSummaryBaseURL", defaultValue: "https://ai-worker.neuxnet.com")
    var meetingSummaryBaseURL: String

    @UserDefault(key: "meetingSummaryAPIKey", defaultValue: "")
    var meetingSummaryAPIKey: String

    @UserDefault(key: "didPromptForScreenRecordingPermission", defaultValue: false)
    var didPromptForScreenRecordingPermission: Bool

    @UserDefault(key: "screenRecordingPermissionPendingRelaunch", defaultValue: false)
    var screenRecordingPermissionPendingRelaunch: Bool

    @OptionalUserDefault(key: "indicatorOriginX")
    var indicatorOriginX: Double?

    @OptionalUserDefault(key: "indicatorOriginY")
    var indicatorOriginY: Double?

    @UserDefault(
        key: "llmOptimizationPrompt",
        defaultValue: "You are an expert transcription editor. Improve clarity and readability while preserving the original meaning, intent, tone, and language. Remove filler words, stutters, and obvious disfluencies only when safe. Keep names, numbers, facts, and ordering unchanged. Fix punctuation and sentence boundaries so the text is easy to read and unambiguous. If the output text is Traditional Chinese, convert it to Simplified Chinese while preserving meaning and terminology. Do not add new information or reinterpret meaning. Return only the edited transcript text."
    )
    var llmOptimizationPrompt: String

    // Backward compatibility
    var groqAPIKey: String {
        get { deepInfraAPIKey }
        set { deepInfraAPIKey = newValue }
    }

    var groqASRModel: String {
        get { asrModel }
        set { asrModel = newValue }
    }

    var groqLLMModel: String {
        get { llmModel }
        set { llmModel = newValue }
    }

    func sanitizeMeetingSummaryBaseURL() {
        let canonical = MeetingSummaryConfig.defaultBaseURL
        if meetingSummaryBaseURL != canonical {
            meetingSummaryBaseURL = canonical
        }
    }
}

struct VisibleSettingsSnapshot: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let modifierOnlyHotkey: String
    let indicatorOriginX: Double?
    let indicatorOriginY: Double?
    let asrAPIBaseURL: String
    let asrAPIKey: String
    let asrModel: String
    let llmAPIBaseURL: String
    let llmAPIKey: String
    let llmModel: String
    let llmOptimizationPrompt: String
}

enum VisibleSettingsStore {
    static func exportVisibleSettings(to url: URL) throws {
        let snapshot = AppPreferences.shared.makeVisibleSettingsSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func importVisibleSettings(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(VisibleSettingsSnapshot.self, from: data)
        AppPreferences.shared.applyVisibleSettingsSnapshot(snapshot)
    }
}

private extension AppPreferences {
    func makeVisibleSettingsSnapshot() -> VisibleSettingsSnapshot {
        VisibleSettingsSnapshot(
            version: VisibleSettingsSnapshot.currentVersion,
            modifierOnlyHotkey: modifierOnlyHotkey,
            indicatorOriginX: indicatorOriginX,
            indicatorOriginY: indicatorOriginY,
            asrAPIBaseURL: asrAPIBaseURL,
            asrAPIKey: asrAPIKey,
            asrModel: asrModel,
            llmAPIBaseURL: llmAPIBaseURL,
            llmAPIKey: llmAPIKey,
            llmModel: llmModel,
            llmOptimizationPrompt: llmOptimizationPrompt
        )
    }

    func applyVisibleSettingsSnapshot(_ snapshot: VisibleSettingsSnapshot) {
        modifierOnlyHotkey = snapshot.modifierOnlyHotkey
        indicatorOriginX = snapshot.indicatorOriginX
        indicatorOriginY = snapshot.indicatorOriginY
        asrAPIBaseURL = snapshot.asrAPIBaseURL
        asrAPIKey = snapshot.asrAPIKey
        asrModel = snapshot.asrModel
        llmAPIBaseURL = snapshot.llmAPIBaseURL
        llmAPIKey = snapshot.llmAPIKey
        llmModel = snapshot.llmModel
        llmOptimizationPrompt = snapshot.llmOptimizationPrompt
    }
}
