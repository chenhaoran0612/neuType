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

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {}
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
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
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
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

    @UserDefault(key: "meetingVibeVoiceBaseURL", defaultValue: "http://workspace.featurize.cn:12930")
    var meetingVibeVoiceBaseURL: String

    @UserDefault(key: "meetingVibeVoiceAPIPrefix", defaultValue: "/gradio_api")
    var meetingVibeVoiceAPIPrefix: String

    @UserDefault(key: "meetingVibeVoiceContextInfo", defaultValue: "")
    var meetingVibeVoiceContextInfo: String

    @UserDefault(key: "meetingVibeVoiceMaxNewTokens", defaultValue: 16384)
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
}
