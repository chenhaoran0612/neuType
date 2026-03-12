import Carbon
import Foundation
import SwiftUI

class SettingsViewModel: ObservableObject {
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    init() {
        modifierOnlyHotkey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .rightOption
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
    var body: some View {
        Form {
            Section("Start Recording Hotkey") {
                Picker("Modifier key", selection: $viewModel.modifierOnlyHotkey) {
                    ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            }
        }
        .padding()
        .frame(width: 560)
        .background(Color(.windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/Starmel/NeuType")!)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
    }
}
