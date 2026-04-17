import AppKit
import Carbon
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var asrAPIBaseURL: String {
        didSet { AppPreferences.shared.asrAPIBaseURL = asrAPIBaseURL }
    }

    @Published var asrAPIKey: String {
        didSet { AppPreferences.shared.asrAPIKey = asrAPIKey }
    }

    @Published var asrModel: String {
        didSet { AppPreferences.shared.asrModel = asrModel }
    }

    @Published var llmAPIBaseURL: String {
        didSet { AppPreferences.shared.llmAPIBaseURL = llmAPIBaseURL }
    }

    @Published var llmAPIKey: String {
        didSet { AppPreferences.shared.llmAPIKey = llmAPIKey }
    }

    @Published var llmModel: String {
        didSet { AppPreferences.shared.llmModel = llmModel }
    }

    @Published var llmOptimizationPrompt: String {
        didSet { AppPreferences.shared.llmOptimizationPrompt = llmOptimizationPrompt }
    }

    @Published var selectedLogKind: RequestLogKind = .asr
    @Published var isAdjustingIndicatorPosition = false
    @Published var settingsTransferStatusMessage: String?
    @Published var settingsTransferStatusIsError = false

    @MainActor
    var filteredLogs: [RequestLogEntry] {
        RequestLogStore.shared.entries
            .filter { $0.kind == selectedLogKind }
            .reversed()
    }

    init() {
        modifierOnlyHotkey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .leftControl
        asrAPIBaseURL = AppPreferences.shared.asrAPIBaseURL
        asrAPIKey = AppPreferences.shared.asrAPIKey.isEmpty ? AppPreferences.shared.groqAPIKey : AppPreferences.shared.asrAPIKey
        asrModel = AppPreferences.shared.asrModel
        llmAPIBaseURL = AppPreferences.shared.llmAPIBaseURL
        llmAPIKey = AppPreferences.shared.llmAPIKey.isEmpty ? AppPreferences.shared.groqAPIKey : AppPreferences.shared.llmAPIKey
        llmModel = AppPreferences.shared.llmModel
        llmOptimizationPrompt = AppPreferences.shared.llmOptimizationPrompt
    }

    func startIndicatorPositionAdjusting() {
        IndicatorWindowManager.shared.showPositionEditor()
        isAdjustingIndicatorPosition = true
    }

    func stopIndicatorPositionAdjustingIfNeeded() {
        guard isAdjustingIndicatorPosition else { return }
        IndicatorWindowManager.shared.hide()
        isAdjustingIndicatorPosition = false
    }

    func reloadFromPreferences() {
        modifierOnlyHotkey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .leftControl
        asrAPIBaseURL = AppPreferences.shared.asrAPIBaseURL
        asrAPIKey = AppPreferences.shared.asrAPIKey.isEmpty ? AppPreferences.shared.groqAPIKey : AppPreferences.shared.asrAPIKey
        asrModel = AppPreferences.shared.asrModel
        llmAPIBaseURL = AppPreferences.shared.llmAPIBaseURL
        llmAPIKey = AppPreferences.shared.llmAPIKey.isEmpty ? AppPreferences.shared.groqAPIKey : AppPreferences.shared.llmAPIKey
        llmModel = AppPreferences.shared.llmModel
        llmOptimizationPrompt = AppPreferences.shared.llmOptimizationPrompt
    }

    func exportVisibleSettings(to url: URL) throws {
        try VisibleSettingsStore.exportVisibleSettings(to: url)
    }

    func importVisibleSettings(from url: URL) throws {
        try VisibleSettingsStore.importVisibleSettings(from: url)
        reloadFromPreferences()
    }

    func presentExportPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.message = "Save the current visible settings as a JSON file."
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "neutype-settings.json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportVisibleSettings(to: url)
            updateTransferStatus(message: "Exported settings to \(url.lastPathComponent)", isError: false)
        } catch {
            updateTransferStatus(message: "Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.message = "Choose a JSON file to import visible settings."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try importVisibleSettings(from: url)
            updateTransferStatus(message: "Imported settings from \(url.lastPathComponent)", isError: false)
        } catch {
            updateTransferStatus(message: "Import failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func updateTransferStatus(message: String, isError: Bool) {
        settingsTransferStatusMessage = message
        settingsTransferStatusIsError = isError
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
        TabView {
            GeneralSettingsTabView(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            RequestLogsTabView(viewModel: viewModel)
                .tabItem {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
        }
        .padding()
        .frame(width: 760, height: 560)
        .background(Color(.windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Import Settings…") {
                    viewModel.presentImportPanel()
                }
                .buttonStyle(.bordered)

                Button("Export Settings…") {
                    viewModel.presentExportPanel()
                }
                .buttonStyle(.bordered)

                if let statusMessage = viewModel.settingsTransferStatusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(viewModel.settingsTransferStatusIsError ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/chenhaoran0612/neuType")!)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
        .onDisappear {
            viewModel.stopIndicatorPositionAdjustingIfNeeded()
        }
    }
}

private struct GeneralSettingsTabView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Press and hold this modifier key to trigger recording globally.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Modifier key", selection: $viewModel.modifierOnlyHotkey) {
                            ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .labelsHidden()

                        HStack(spacing: 8) {
                            Button(
                                viewModel.isAdjustingIndicatorPosition
                                    ? "Position Saved"
                                    : "Adjust Floating Bubble Position"
                            ) {
                                viewModel.startIndicatorPositionAdjusting()
                            }
                            .buttonStyle(.borderedProminent)

                            Text("Drag the bubble and close Settings to save.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Hotkey", systemImage: "keyboard")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledInputField(
                            title: "Base URL",
                            placeholder: "https://api.groq.com/openai/v1",
                            text: $viewModel.asrAPIBaseURL
                        )
                        LabeledInputField(title: "API Key", placeholder: "gsk_...", text: $viewModel.asrAPIKey)
                        LabeledInputField(title: "Model", placeholder: "whisper-large-v3", text: $viewModel.asrModel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("ASR API (OpenAI Compatible)", systemImage: "waveform.badge.mic")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledInputField(
                            title: "Base URL",
                            placeholder: "https://api.groq.com/openai/v1",
                            text: $viewModel.llmAPIBaseURL
                        )
                        LabeledInputField(title: "API Key", placeholder: "gsk_...", text: $viewModel.llmAPIKey)
                        LabeledInputField(title: "Model", placeholder: "openai/gpt-oss-20b", text: $viewModel.llmModel)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Optimization Prompt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $viewModel.llmOptimizationPrompt)
                                .font(.system(size: 12))
                                .frame(minHeight: 96)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("LLM API (OpenAI Compatible)", systemImage: "brain.head.profile")
                }
            }
            .padding(16)
        }
    }
}

private struct RequestLogsTabView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var logStore = RequestLogStore.shared

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Log Type", selection: $viewModel.selectedLogKind) {
                    ForEach(RequestLogKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Text("\(viewModel.filteredLogs.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())

                Button("Clear") {
                    RequestLogStore.shared.clear()
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if viewModel.filteredLogs.isEmpty {
                ContentUnavailableView("No logs yet", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.filteredLogs) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.formatter.string(from: entry.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                Text(entry.message)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(nil)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
    }
}

private struct LabeledInputField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
