import Carbon
import Foundation
import KeyboardShortcuts
import SwiftUI

class SettingsViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }
    @Published var translateToEnglish: Bool { didSet { AppPreferences.shared.translateToEnglish = translateToEnglish } }
    @Published var suppressBlankAudio: Bool { didSet { AppPreferences.shared.suppressBlankAudio = suppressBlankAudio } }
    @Published var showTimestamps: Bool { didSet { AppPreferences.shared.showTimestamps = showTimestamps } }
    @Published var temperature: Double { didSet { AppPreferences.shared.temperature = temperature } }
    @Published var noSpeechThreshold: Double { didSet { AppPreferences.shared.noSpeechThreshold = noSpeechThreshold } }
    @Published var initialPrompt: String { didSet { AppPreferences.shared.initialPrompt = initialPrompt } }
    @Published var useBeamSearch: Bool { didSet { AppPreferences.shared.useBeamSearch = useBeamSearch } }
    @Published var beamSize: Int { didSet { AppPreferences.shared.beamSize = beamSize } }
    @Published var debugMode: Bool { didSet { AppPreferences.shared.debugMode = debugMode } }
    @Published var playSoundOnRecordStart: Bool { didSet { AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart } }
    @Published var useAsianAutocorrect: Bool { didSet { AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect } }
    @Published var removeDisfluency: Bool { didSet { AppPreferences.shared.removeDisfluency = removeDisfluency } }
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    @Published var holdToRecord: Bool { didSet { AppPreferences.shared.holdToRecord = holdToRecord } }
    @Published var addSpaceAfterSentence: Bool { didSet { AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence } }
    @Published var deepInfraAPIKey: String {
        didSet {
            AppPreferences.shared.deepInfraAPIKey = deepInfraAPIKey
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
    }

    init() {
        let prefs = AppPreferences.shared
        selectedLanguage = prefs.whisperLanguage
        translateToEnglish = prefs.translateToEnglish
        suppressBlankAudio = prefs.suppressBlankAudio
        showTimestamps = prefs.showTimestamps
        temperature = prefs.temperature
        noSpeechThreshold = prefs.noSpeechThreshold
        initialPrompt = prefs.initialPrompt
        useBeamSearch = prefs.useBeamSearch
        beamSize = prefs.beamSize
        debugMode = prefs.debugMode
        playSoundOnRecordStart = prefs.playSoundOnRecordStart
        useAsianAutocorrect = prefs.useAsianAutocorrect
        removeDisfluency = prefs.removeDisfluency
        modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        holdToRecord = prefs.holdToRecord
        addSpaceAfterSentence = prefs.addSpaceAfterSentence
        deepInfraAPIKey = prefs.deepInfraAPIKey
    }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]

    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    var removeDisfluency: Bool

    var isAsianLanguage: Bool { Settings.asianLanguages.contains(selectedLanguage) }
    var shouldApplyAsianAutocorrect: Bool { isAsianLanguage && useAsianAutocorrect }

    init() {
        let prefs = AppPreferences.shared
        selectedLanguage = prefs.whisperLanguage
        translateToEnglish = prefs.translateToEnglish
        suppressBlankAudio = prefs.suppressBlankAudio
        showTimestamps = prefs.showTimestamps
        temperature = prefs.temperature
        noSpeechThreshold = prefs.noSpeechThreshold
        initialPrompt = prefs.initialPrompt
        useBeamSearch = prefs.useBeamSearch
        beamSize = prefs.beamSize
        useAsianAutocorrect = prefs.useAsianAutocorrect
        removeDisfluency = prefs.removeDisfluency
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            shortcutSettings.tabItem { Label("Shortcuts", systemImage: "command") }.tag(0)
            transcriptionSettings.tabItem { Label("Transcription", systemImage: "text.bubble") }.tag(1)
            advancedSettings.tabItem { Label("Advanced", systemImage: "gear") }.tag(2)
        }
        .padding()
        .frame(width: 560)
        .background(Color(.windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/Starmel/WangWhisper")!)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
    }

    private var shortcutSettings: some View {
        Form {
            Section("Keyboard Shortcuts") {
                HStack {
                    Text("Start/Stop Recording")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleRecord)
                }

                HStack {
                    Text("Cancel Recording")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .escape)
                }
            }

            Section("Recording Behavior") {
                Toggle("Hold key to record", isOn: $viewModel.holdToRecord)
                Toggle("Add space after sentence", isOn: $viewModel.addSpaceAfterSentence)
                Toggle("Play sound when recording starts", isOn: $viewModel.playSoundOnRecordStart)

                Picker("Modifier-only hotkey", selection: $viewModel.modifierOnlyHotkey) {
                    ForEach(ModifierKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            }
        }
    }

    private var transcriptionSettings: some View {
        Form {
            Section("Language") {
                Picker("Transcription language", selection: $viewModel.selectedLanguage) {
                    ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                        Text(LanguageUtil.languageNames[code] ?? code).tag(code)
                    }
                }
            }

            Section("Recognition") {
                Toggle("Translate to English", isOn: $viewModel.translateToEnglish)
                Toggle("Suppress blank audio", isOn: $viewModel.suppressBlankAudio)
                Toggle("Show timestamps", isOn: $viewModel.showTimestamps)
                Toggle("Use beam search", isOn: $viewModel.useBeamSearch)

                Stepper("Beam size: \(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)

                VStack(alignment: .leading) {
                    Text("Temperature: \(String(format: "%.2f", viewModel.temperature))")
                    Slider(value: $viewModel.temperature, in: 0...1)
                }

                VStack(alignment: .leading) {
                    Text("No speech threshold: \(String(format: "%.2f", viewModel.noSpeechThreshold))")
                    Slider(value: $viewModel.noSpeechThreshold, in: 0...1)
                }

                TextField("Initial prompt", text: $viewModel.initialPrompt)
            }
        }
    }

    private var advancedSettings: some View {
        Form {
            Section("DeepInfra") {
                SecureField("API Key", text: $viewModel.deepInfraAPIKey)
                Text("Using openai/whisper-large-v3-turbo via DeepInfra API")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Text Processing") {
                Toggle("Enable Asian autocorrect", isOn: $viewModel.useAsianAutocorrect)
                Toggle("Remove disfluencies", isOn: $viewModel.removeDisfluency)
                Text("Disfluency model: Qwen/Qwen3-14B")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Diagnostics") {
                Toggle("Debug mode", isOn: $viewModel.debugMode)
            }
        }
    }
}
