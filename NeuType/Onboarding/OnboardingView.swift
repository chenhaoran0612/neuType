import SwiftUI

final class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet { AppPreferences.shared.whisperLanguage = selectedLanguage }
    }
    @Published var useAsianAutocorrect: Bool {
        didSet { AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect }
    }
    init() {
        let language = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = language
        selectedLanguage = language
        useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect
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
            Text("Welcome to NeuType")
                .font(.system(size: 30, weight: .bold))

            Text("A lightweight recorder with cloud transcription.")
                .foregroundColor(.secondary)

            Form {
                Picker("Language", selection: $viewModel.selectedLanguage) {
                    ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                        Text(LanguageUtil.languageNames[code] ?? code).tag(code)
                    }
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
