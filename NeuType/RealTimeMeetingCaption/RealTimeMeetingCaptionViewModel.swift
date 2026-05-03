import Foundation

@MainActor
final class RealTimeMeetingCaptionViewModel: ObservableObject {
    static let shared = RealTimeMeetingCaptionViewModel()
    static let visibleSubtitleLimit = 10

    @Published var targetLanguage: RealTimeMeetingCaptionLanguage {
        didSet {
            preferences.targetLanguage = targetLanguage
            guard oldValue != targetLanguage, canRestartForTargetLanguageChange else { return }
            guard languageRestartTask == nil else { return }
            languageRestartTask = Task { [weak self] in
                await self?.restartForTargetLanguageChange()
            }
        }
    }

    @Published var subtitleRetentionCount: Int {
        didSet {
            subtitleRetentionCount = max(1, subtitleRetentionCount)
            preferences.subtitleRetentionCount = subtitleRetentionCount
        }
    }

    @Published var chunkDurationMS: Int {
        didSet {
            chunkDurationMS = max(1, chunkDurationMS)
            preferences.chunkDurationMS = chunkDurationMS
        }
    }

    @Published private(set) var state: RealTimeMeetingCaptionState = .idle
    @Published private(set) var segments: [RealTimeMeetingCaptionSegment] = []
    @Published private(set) var logs: [RealTimeMeetingCaptionLogEntry] = []
    private var finalizedSegments: [RealTimeMeetingCaptionSegment] = []
    private var liveSegment: RealTimeMeetingCaptionSegment?

    private let preferences: any LiveMeetingCaptionPreferencesProviding
    private let credentialsProvider: @Sendable () -> LiveMeetingCaptionCredentials
    private let providerFactory: @Sendable (LiveMeetingCaptionSessionConfiguration) -> any LiveMeetingCaptionProviding
    private let audioCapture: any LiveMeetingAudioCapturing

    private var activeRunID: UUID?
    private var currentProvider: (any LiveMeetingCaptionProviding)?
    private var eventTask: Task<Void, Never>?
    private var audioFrameWatchdogTask: Task<Void, Never>?
    private var languageRestartTask: Task<Void, Never>?
    private var audioChunker: LiveMeetingAudioChunker
    private var receivedAudioFrameCount = 0
    private var sentAudioChunkCount = 0

    var isRunning: Bool {
        switch state {
        case .connecting, .streaming, .stopping:
            return true
        case .idle, .failed:
            return false
        }
    }

    var canStart: Bool {
        credentialsProvider().isConfigured
    }

    private var canRestartForTargetLanguageChange: Bool {
        switch state {
        case .connecting, .streaming:
            return activeRunID != nil
        case .idle, .failed, .stopping:
            return false
        }
    }

    init(
        preferences: any LiveMeetingCaptionPreferencesProviding = AppPreferences.shared,
        credentialsProvider: @escaping @Sendable () -> LiveMeetingCaptionCredentials = {
            LiveMeetingCaptionCredentials(
                subscriptionKey: LiveMeetingCaptionCredentialsStore.subscriptionKey,
                region: LiveMeetingCaptionCredentialsStore.region
            )
        },
        providerFactory: @escaping @Sendable (LiveMeetingCaptionSessionConfiguration) -> any LiveMeetingCaptionProviding = { _ in
            AzureLiveCaptionProvider()
        },
        audioCapture: any LiveMeetingAudioCapturing = SystemMicrophoneAudioCapture()
    ) {
        self.preferences = preferences
        self.credentialsProvider = credentialsProvider
        self.providerFactory = providerFactory
        self.audioCapture = audioCapture
        self.targetLanguage = preferences.targetLanguage
        self.subtitleRetentionCount = max(1, preferences.subtitleRetentionCount)
        self.chunkDurationMS = max(1, preferences.chunkDurationMS)
        self.audioChunker = LiveMeetingAudioChunker(chunkDurationMS: max(1, preferences.chunkDurationMS))
    }

    func start() async {
        await beginSession(resetLogs: true, resetSegments: true)
    }

    func clearSegments() {
        resetDisplayedSegments()
        appendLog("字幕流已清空")
    }

    private func beginSession(resetLogs: Bool, resetSegments: Bool) async {
        guard !isRunning else { return }

        let credentials = credentialsProvider()
        guard credentials.isConfigured else {
            state = .failed(message: LiveMeetingCaptionError.missingCredentials.localizedDescription)
            appendLog("启动失败：缺少 Azure Speech Key 或 Region")
            return
        }

        let runID = UUID()
        activeRunID = runID
        if resetSegments {
            resetDisplayedSegments()
        }
        if resetLogs {
            logs = []
        }
        audioChunker = LiveMeetingAudioChunker(chunkDurationMS: chunkDurationMS)
        receivedAudioFrameCount = 0
        sentAudioChunkCount = 0
        state = .connecting

        let configuration = LiveMeetingCaptionSessionConfiguration(
            credentials: credentials,
            targetLanguage: targetLanguage,
            subtitleRetentionCount: subtitleRetentionCount,
            chunkDurationMS: chunkDurationMS
        )

        let provider = providerFactory(configuration)
        currentProvider = provider
        appendLog(
            "开始连接：Azure Speech Translation，sourceCandidates=\(RealTimeMeetingCaptionLanguage.azureAutoDetectSourceLanguageCodes.joined(separator: ",")), to=\(targetLanguage.azureTargetLanguageCode) (\(targetLanguage.displayName)), chunk=\(chunkDurationMS)ms"
        )

        do {
            let stream = try await provider.start(configuration: configuration)
            eventTask = Task { [weak self] in
                for await event in stream {
                    await self?.handle(event: event, runID: runID)
                }
            }

            try await audioCapture.start { [weak self] data in
                Task { [weak self] in
                    await self?.handleAudioFrame(data, runID: runID)
                }
            }
            appendLog("音频采集已启动，等待服务端字幕事件")
            audioFrameWatchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.reportNoAudioFramesIfNeeded(runID: runID)
            }
        } catch {
            appendLog("启动异常：\(error.localizedDescription)")
            await terminate(runID: runID, finalState: .failed(message: error.localizedDescription))
        }
    }

    func stop() async {
        languageRestartTask?.cancel()
        languageRestartTask = nil
        guard let runID = activeRunID else {
            state = .idle
            return
        }

        await terminate(runID: runID, finalState: .idle)
    }

    private func restartForTargetLanguageChange() async {
        defer { languageRestartTask = nil }
        let requestedLanguage = targetLanguage
        guard let runID = activeRunID, state != .stopping else { return }
        appendLog("切换目标语言：\(requestedLanguage.displayName)，正在重建字幕连接")
        await terminate(runID: runID, finalState: .idle, logCompletion: false)
        guard !Task.isCancelled else { return }
        if targetLanguage != requestedLanguage {
            appendLog("目标语言更新为：\(targetLanguage.displayName)，继续重建字幕连接")
        }
        await beginSession(resetLogs: false, resetSegments: true)
    }

    private func handle(event: RealTimeMeetingCaptionEvent, runID: UUID) async {
        guard activeRunID == runID else { return }

        switch event {
        case .started:
            state = .streaming
            appendLog("Azure Speech Translation 会话已建立")
        case .segment(let segment):
            state = .streaming
            let normalized = normalize(segment: segment)
            let displayLanguage = normalized.targetLanguage ?? targetLanguage
            if displayLanguage == .arabic && !normalized.isFinal {
                return
            }
            guard LiveCaptionLanguageValidator.isDisplayable(normalized.translatedText, as: displayLanguage) else {
                appendLog("丢弃字幕 #\(normalized.id)：译文不符合目标语言 \(displayLanguage.displayName)")
                return
            }
            appendLog(
                "字幕 #\(normalized.id) \(normalized.isFinal ? "final" : "partial") 目标=\(displayLanguage.displayName) 原文=\"\(normalized.sourceText)\" 译文=\"\(normalized.translatedText)\""
            )
            merge(segment: normalized)
        case .error(let message):
            appendLog("服务端错误：\(message)")
            await terminate(runID: runID, finalState: .failed(message: message))
        }
    }

    private func handleAudioFrame(_ data: Data, runID: UUID) async {
        guard activeRunID == runID, isRunning || state == .connecting else { return }
        guard let provider = currentProvider else { return }

        receivedAudioFrameCount += 1
        if shouldLogAudioFlow(count: receivedAudioFrameCount) {
            appendLog(
                "采集音频帧 #\(receivedAudioFrameCount)：\(data.count) bytes，chunkSize=\(audioChunker.targetChunkByteSize)，pendingBefore=\(audioChunker.pendingByteCount)"
            )
        }

        let chunks = audioChunker.append(data)
        if !chunks.isEmpty {
            appendLog("音频切片：生成 \(chunks.count) 个 chunk，pendingAfter=\(audioChunker.pendingByteCount) bytes")
        }

        for chunk in chunks {
            guard activeRunID == runID else { return }
            do {
                try await provider.sendAudioFrame(chunk)
                sentAudioChunkCount += 1
                if shouldLogAudioFlow(count: sentAudioChunkCount) {
                    appendLog("已发送音频 chunk #\(sentAudioChunkCount)：\(chunk.count) bytes")
                }
            } catch {
                appendLog("音频帧发送失败：\(error.localizedDescription)")
                await terminate(runID: runID, finalState: .failed(message: error.localizedDescription))
                return
            }
        }
    }

    private func reportNoAudioFramesIfNeeded(runID: UUID) {
        guard activeRunID == runID, isRunning, receivedAudioFrameCount == 0 else { return }
        appendLog("2 秒内未收到音频帧：请检查输入设备是否有声音、麦克风权限是否打开，或当前选择的系统输入源是否正确")
    }

    private func normalize(segment: RealTimeMeetingCaptionSegment) -> RealTimeMeetingCaptionSegment {
        RealTimeMeetingCaptionSegment(
            id: segment.id,
            sourceText: segment.sourceText,
            translatedText: segment.translatedText,
            isFinal: segment.isFinal,
            targetLanguage: segment.targetLanguage ?? targetLanguage,
            startMilliseconds: segment.startMilliseconds,
            endMilliseconds: segment.endMilliseconds,
            lastUpdatedAt: segment.lastUpdatedAt
        )
    }

    private func merge(segment: RealTimeMeetingCaptionSegment) {
        if segment.isFinal {
            liveSegment = liveSegment?.id == segment.id ? nil : liveSegment
            if let index = finalizedSegments.firstIndex(where: { $0.id == segment.id }) {
                finalizedSegments[index] = segment
            } else {
                finalizedSegments.append(segment)
            }
            finalizedSegments.sort { $0.id < $1.id }
            if finalizedSegments.count > Self.visibleSubtitleLimit {
                finalizedSegments = Array(finalizedSegments.suffix(Self.visibleSubtitleLimit))
            }
        } else if finalizedSegments.contains(where: { $0.id == segment.id }) {
            return
        } else {
            liveSegment = segment
        }

        publishDisplayedSegments()
    }

    private func resetDisplayedSegments() {
        finalizedSegments = []
        liveSegment = nil
        segments = []
    }

    private func publishDisplayedSegments() {
        var nextSegments = Array(finalizedSegments.reversed())
        if let liveSegment, !finalizedSegments.contains(where: { $0.id == liveSegment.id }) {
            nextSegments.insert(liveSegment, at: 0)
        }
        segments = nextSegments
    }

    private func terminate(
        runID: UUID,
        finalState: RealTimeMeetingCaptionState,
        logCompletion: Bool = true
    ) async {
        guard activeRunID == runID else { return }

        activeRunID = nil
        state = .stopping

        let provider = currentProvider
        let task = eventTask
        let watchdogTask = audioFrameWatchdogTask
        eventTask = nil
        audioFrameWatchdogTask = nil
        currentProvider = nil
        watchdogTask?.cancel()

        await audioCapture.stop()

        if let residual = audioChunker.flush(), !residual.isEmpty {
            do {
                try await provider?.sendAudioFrame(residual)
                sentAudioChunkCount += 1
                appendLog("已发送停止前残余音频 chunk #\(sentAudioChunkCount)：\(residual.count) bytes")
            } catch {
                appendLog("停止前残余音频发送失败：\(error.localizedDescription)")
            }
        }

        await provider?.stop()
        task?.cancel()

        state = finalState
        if logCompletion {
            appendLog("会话结束：\(stateLogDescription(finalState))")
        }
    }

    private func appendLog(_ message: String) {
        var nextLogs = logs
        nextLogs.append(RealTimeMeetingCaptionLogEntry(message: message))
        if nextLogs.count > 120 {
            nextLogs = Array(nextLogs.suffix(120))
        }
        logs = nextLogs
        RequestLogStore.log(.usage, "Live captions: \(message)")
    }

    private func shouldLogAudioFlow(count: Int) -> Bool {
        count <= 3 || count.isMultiple(of: 20)
    }

    private func stateLogDescription(_ state: RealTimeMeetingCaptionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .streaming:
            return "streaming"
        case .stopping:
            return "stopping"
        case .failed(let message):
            return "failed \(message)"
        }
    }
}
