import AppKit
import Carbon
import Foundation
import KeyboardShortcuts
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

    @Published var meetingVibeVoiceBaseURL: String {
        didSet { AppPreferences.shared.meetingVibeVoiceBaseURL = meetingVibeVoiceBaseURL }
    }

    @Published var meetingVibeVoiceAPIPrefix: String {
        didSet { AppPreferences.shared.meetingVibeVoiceAPIPrefix = meetingVibeVoiceAPIPrefix }
    }

    @Published var meetingVibeVoiceAPIKey: String {
        didSet { AppPreferences.shared.meetingVibeVoiceAPIKey = meetingVibeVoiceAPIKey }
    }

    @Published var meetingVibeVoiceContextInfo: String {
        didSet { AppPreferences.shared.meetingVibeVoiceContextInfo = meetingVibeVoiceContextInfo }
    }

    @Published var meetingVibeVoiceMaxNewTokens: Double {
        didSet { AppPreferences.shared.meetingVibeVoiceMaxNewTokens = Int(meetingVibeVoiceMaxNewTokens) }
    }

    @Published var meetingVibeVoiceTemperature: Double {
        didSet { AppPreferences.shared.meetingVibeVoiceTemperature = meetingVibeVoiceTemperature }
    }

    @Published var meetingVibeVoiceTopP: Double {
        didSet { AppPreferences.shared.meetingVibeVoiceTopP = meetingVibeVoiceTopP }
    }

    @Published var meetingVibeVoiceDoSample: Bool {
        didSet { AppPreferences.shared.meetingVibeVoiceDoSample = meetingVibeVoiceDoSample }
    }

    @Published var meetingVibeVoiceRepetitionPenalty: Double {
        didSet { AppPreferences.shared.meetingVibeVoiceRepetitionPenalty = meetingVibeVoiceRepetitionPenalty }
    }

    @Published var meetingSummaryBaseURL: String {
        didSet { AppPreferences.shared.meetingSummaryBaseURL = meetingSummaryBaseURL }
    }

    @Published var meetingSummaryAPIKey: String {
        didSet { AppPreferences.shared.meetingSummaryAPIKey = meetingSummaryAPIKey }
    }

    @Published var selectedLogKind: RequestLogKind = .asr
    @Published var isAdjustingIndicatorPosition = false
    @Published var settingsTransferStatusMessage: String?
    @Published var settingsTransferStatusIsError = false
    @Published var meetingShortcutError: String?

    @MainActor
    var filteredLogs: [RequestLogEntry] {
        RequestLogStore.shared.entries
            .filter { $0.kind == selectedLogKind }
            .reversed()
    }

    init() {
        let meetingConfig = AppPreferences.shared.meetingVibeVoiceConfig
        modifierOnlyHotkey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .leftControl
        asrAPIBaseURL = AppPreferences.shared.asrAPIBaseURL
        asrAPIKey = AppPreferences.shared.asrAPIKey.isEmpty ? AppPreferences.shared.groqAPIKey : AppPreferences.shared.asrAPIKey
        asrModel = AppPreferences.shared.asrModel
        llmAPIBaseURL = AppPreferences.shared.llmAPIBaseURL
        llmAPIKey = AppPreferences.shared.llmAPIKey.isEmpty ? AppPreferences.shared.groqAPIKey : AppPreferences.shared.llmAPIKey
        llmModel = AppPreferences.shared.llmModel
        llmOptimizationPrompt = AppPreferences.shared.llmOptimizationPrompt
        meetingVibeVoiceBaseURL = meetingConfig.baseURL
        meetingVibeVoiceAPIPrefix = meetingConfig.apiPrefix
        meetingVibeVoiceAPIKey = AppPreferences.shared.meetingVibeVoiceAPIKey
        meetingVibeVoiceContextInfo = meetingConfig.contextInfo
        meetingVibeVoiceMaxNewTokens = Double(meetingConfig.maxNewTokens)
        meetingVibeVoiceTemperature = meetingConfig.temperature
        meetingVibeVoiceTopP = meetingConfig.topP
        meetingVibeVoiceDoSample = meetingConfig.doSample
        meetingVibeVoiceRepetitionPenalty = meetingConfig.repetitionPenalty
        meetingSummaryBaseURL = AppPreferences.shared.meetingSummaryBaseURL
        meetingSummaryAPIKey = AppPreferences.shared.meetingSummaryAPIKey
        validateMeetingShortcut()
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
        validateMeetingShortcut()
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

    func validateMeetingShortcut() {
        let validator = MeetingShortcutValidator(
            dictationShortcut: KeyboardShortcuts.Shortcut(name: .toggleRecord)
        )
        let meetingShortcut = KeyboardShortcuts.Shortcut(name: .toggleMeetingRecord)
        meetingShortcutError = validator.canUse(meetingShortcut)
            ? nil
            : "Meeting shortcut cannot match the dictation shortcut."
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
    @StateObject private var permissionsManager = PermissionsManager()

    var body: some View {
        TabView {
            GeneralSettingsTabView(
                viewModel: viewModel,
                permissionsManager: permissionsManager
            )
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
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        PermissionStatusRow(
                            title: "麦克风",
                            isGranted: permissionsManager.isMicrophonePermissionGranted,
                            statusText: nil,
                            grantedText: "已授权，可用于语音输入和会议录制。",
                            deniedText: "未授权，语音输入和会议录制将不可用。",
                            buttonTitle: permissionsManager.isMicrophonePermissionGranted ? "打开设置" : "请求授权"
                        ) {
                            permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                        }

                        Divider()

                        PermissionStatusRow(
                            title: "辅助功能",
                            isGranted: permissionsManager.isAccessibilityPermissionGranted,
                            statusText: nil,
                            grantedText: "已授权，可用于全局快捷键和系统级输入。",
                            deniedText: "未授权，全局快捷键和部分系统级输入会失效。",
                            buttonTitle: permissionsManager.isAccessibilityPermissionGranted ? "打开设置" : "请求授权"
                        ) {
                            permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences()
                        }

                        Divider()

                        PermissionStatusRow(
                            title: "屏幕录制",
                            isGranted: permissionsManager.isScreenRecordingPermissionGranted,
                            statusText: screenRecordingStatusText,
                            grantedText: "已授权，可用于会议记录中的系统音频采集。",
                            deniedText: screenRecordingDeniedText,
                            buttonTitle: screenRecordingButtonTitle
                        ) {
                            switch permissionsManager.screenRecordingPermissionState {
                            case .granted:
                                permissionsManager.openSystemPreferences(for: .screenRecording)
                            case .needsAuthorization:
                                permissionsManager.requestScreenRecordingPermissionOrOpenSystemPreferences()
                            case .needsRelaunch:
                                permissionsManager.relaunchApplication()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("System Permissions", systemImage: "checkmark.shield")
                }

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

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Meeting shortcut")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            KeyboardShortcuts.Recorder(for: .toggleMeetingRecord)
                                .onChange(of: KeyboardShortcuts.Shortcut(name: .toggleMeetingRecord)) { _, _ in
                                    viewModel.validateMeetingShortcut()
                                }

                            if let meetingShortcutError = viewModel.meetingShortcutError {
                                Text(meetingShortcutError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else {
                                Text("Used only for Meeting Minutes recording.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
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

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Meeting transcription uses the remote VibeVoice ASR OpenAI-compatible Chat Completions API. Base URL usually stays as https://tokenhubpro.com. You can also paste the full endpoint https://tokenhubpro.com/v1/chat/completions directly, and API Prefix is typically left empty.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        LabeledInputField(
                            title: "Base URL",
                            placeholder: "https://tokenhubpro.com",
                            text: $viewModel.meetingVibeVoiceBaseURL
                        )
                        LabeledInputField(
                            title: "API Prefix",
                            placeholder: "(optional)",
                            text: $viewModel.meetingVibeVoiceAPIPrefix
                        )
                        LabeledInputField(
                            title: "API Key",
                            placeholder: "VibeVoice service key",
                            text: $viewModel.meetingVibeVoiceAPIKey
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Context Info")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextEditor(text: $viewModel.meetingVibeVoiceContextInfo)
                                .font(.system(size: 12))
                                .frame(minHeight: 72)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Max New Tokens")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(value: $viewModel.meetingVibeVoiceMaxNewTokens, in: 512...16384, step: 256)
                                Text("\(Int(viewModel.meetingVibeVoiceMaxNewTokens))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                Text("Recommended: 8192 for tokenhubpro.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Temperature")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(value: $viewModel.meetingVibeVoiceTemperature, in: 0.0...2.0, step: 0.1)
                                Text(String(format: "%.1f", viewModel.meetingVibeVoiceTemperature))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Top P")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(value: $viewModel.meetingVibeVoiceTopP, in: 0.0...1.0, step: 0.05)
                                Text(String(format: "%.2f", viewModel.meetingVibeVoiceTopP))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Repetition Penalty")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Slider(value: $viewModel.meetingVibeVoiceRepetitionPenalty, in: 1.0...1.2, step: 0.01)
                                Text(String(format: "%.2f", viewModel.meetingVibeVoiceRepetitionPenalty))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }

                        Toggle("Enable sampling", isOn: $viewModel.meetingVibeVoiceDoSample)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Meeting ASR (VibeVoice)", systemImage: "person.2.wave.2")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Meeting summaries are submitted to ai-worker after transcript completion. The service endpoint is fixed to https://ai-worker.neuxnet.com; only the API key is required here.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        LabeledInputField(
                            title: "API Key",
                            placeholder: "ntm_xxx",
                            text: $viewModel.meetingSummaryAPIKey
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Meeting Summary Service", systemImage: "text.document.star")
                }
            }
            .padding(16)
        }
    }

    private var screenRecordingStatusText: String {
        switch permissionsManager.screenRecordingPermissionState {
        case .granted:
            return "已授权"
        case .needsAuthorization:
            return "未授权"
        case .needsRelaunch:
            return "需重启"
        }
    }

    private var screenRecordingDeniedText: String {
        switch permissionsManager.screenRecordingPermissionState {
        case .granted:
            return "已授权，可用于会议记录中的系统音频采集。"
        case .needsAuthorization:
            return "未授权，会议记录无法采集系统音频。"
        case .needsRelaunch:
            return "已在系统设置中授权，重启 NeuType 后才能生效。"
        }
    }

    private var screenRecordingButtonTitle: String {
        switch permissionsManager.screenRecordingPermissionState {
        case .granted:
            return "打开设置"
        case .needsAuthorization:
            return "请求授权"
        case .needsRelaunch:
            return "重新启动"
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let isGranted: Bool
    let statusText: String?
    let grantedText: String
    let deniedText: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? Color.green : Color.red)
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))

                    Text(statusText ?? (isGranted ? "已授权" : "未授权"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                }

                Text(isGranted ? grantedText : deniedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var statusColor: Color {
        switch statusText {
        case "需重启":
            return .orange
        default:
            return isGranted ? .green : .red
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
