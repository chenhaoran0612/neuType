import SwiftUI

enum OnboardingShortcutOption: String, CaseIterable {
    case keyCombination
    case rightOption
}

final class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet { AppPreferences.shared.whisperLanguage = selectedLanguage }
    }
    @Published var useAsianAutocorrect: Bool {
        didSet { AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect }
    }
    @Published var selectedShortcut: OnboardingShortcutOption {
        didSet {
            switch selectedShortcut {
            case .keyCombination:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
            case .rightOption:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.rightOption.rawValue
            }
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    init() {
        let language = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = language
        selectedLanguage = language
        useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect

        let current = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        if current == .none && !AppPreferences.shared.hasCompletedOnboarding {
            selectedShortcut = .rightOption
            AppPreferences.shared.modifierOnlyHotkey = ModifierKey.rightOption.rawValue
        } else {
            selectedShortcut = current == .rightOption ? .rightOption : .keyCombination
        }
    }

    func completeOnboarding() {
        AppPreferences.shared.hasCompletedOnboarding = true
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = OnboardingViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to youmi-uu")
                .font(.system(size: 30, weight: .bold))

            Text("A lightweight recorder with cloud transcription.")
                .foregroundColor(.secondary)

            Form {
                Picker("Language", selection: $viewModel.selectedLanguage) {
                    ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                        Text(LanguageUtil.languageNames[code] ?? code).tag(code)
                    }
                }

                Picker("Shortcut Mode", selection: $viewModel.selectedShortcut) {
                    Text("Keyboard shortcut").tag(OnboardingShortcutOption.keyCombination)
                    Text("Right Option only").tag(OnboardingShortcutOption.rightOption)
                }

                Toggle("Enable Asian autocorrect", isOn: $viewModel.useAsianAutocorrect)
            }

            HStack {
                Spacer()
                Button("Get Started") {
                    viewModel.completeOnboarding()
                    appState.hasCompletedOnboarding = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 450, height: 500)
    }
}

#Preview {
    OnboardingView().environmentObject(AppState())
}
