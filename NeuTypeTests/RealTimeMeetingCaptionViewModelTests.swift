import XCTest
@testable import NeuType

@MainActor
final class RealTimeMeetingCaptionViewModelTests: XCTestCase {
    func testStartUsesTargetLanguageOnly() async {
        let provider = StubLiveMeetingCaptionProvider()
        let viewModel = makeViewModel(provider: provider)
        viewModel.targetLanguage = .english

        await viewModel.start()

        XCTAssertEqual(provider.startCalls.count, 1)
        XCTAssertEqual(provider.startCalls.first?.targetLanguage, .english)
        XCTAssertTrue(viewModel.logs.contains(where: { $0.message.contains("to=en (英文)") }))
    }

    func testStartRejectsMissingAzureCredentials() async {
        let provider = StubLiveMeetingCaptionProvider()
        let viewModel = makeViewModel(
            provider: provider,
            credentials: LiveMeetingCaptionCredentials(subscriptionKey: "", region: "")
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.state, .failed(message: "请先在设置中填写 Azure Speech Key 和 Region。"))
        XCTAssertEqual(provider.startCalls.count, 0)
    }

    func testSegmentsKeepOneLiveAndFinalSegmentsInDescendingDisplayOrder() async {
        let provider = StubLiveMeetingCaptionProvider()
        let viewModel = makeViewModel(provider: provider)

        await viewModel.start()
        provider.emit(.started)
        provider.emit(.segment(.fixture(id: 1, sourceText: "hello", translatedText: "你好", isFinal: true)))
        provider.emit(.segment(.fixture(id: 2, sourceText: "world", translatedText: "世界", isFinal: false)))
        provider.emit(.segment(.fixture(id: 2, sourceText: "world.", translatedText: "世界。", isFinal: true)))
        provider.emit(.segment(.fixture(id: 3, sourceText: "late partial", translatedText: "迟到临时", isFinal: false)))

        let didReceiveSegments = await waitUntil {
            viewModel.segments.count == 3 && viewModel.segments.first?.id == 3
        }

        XCTAssertTrue(didReceiveSegments)
        XCTAssertEqual(viewModel.segments.map(\.id), [3, 2, 1])
        XCTAssertEqual(viewModel.segments.map(\.translatedText), ["迟到临时", "世界。", "你好"])
        XCTAssertEqual(viewModel.segments.map(\.targetLanguage), [.chineseSimplified, .chineseSimplified, .chineseSimplified])
        XCTAssertEqual(viewModel.state, .streaming)
    }

    func testFinalSegmentsKeepNewestTenInDescendingDisplayOrder() async {
        let provider = StubLiveMeetingCaptionProvider()
        let viewModel = makeViewModel(provider: provider)

        await viewModel.start()
        for id in 1...12 {
            provider.emit(.segment(.fixture(id: id, sourceText: "source \(id)", translatedText: "译文 \(id)", isFinal: true)))
        }
        let didTrim = await waitUntil { viewModel.segments.count == 10 }

        XCTAssertTrue(didTrim)
        XCTAssertEqual(viewModel.segments.map(\.id), Array((3...12).reversed()))
    }

    func testClearSegmentsEmptiesSubtitleStreamWithoutStoppingSession() async {
        let provider = StubLiveMeetingCaptionProvider()
        let viewModel = makeViewModel(provider: provider)

        await viewModel.start()
        provider.emit(.segment(.fixture(id: 1, sourceText: "hello", translatedText: "你好", isFinal: true)))
        _ = await waitUntil { viewModel.segments.count == 1 }

        viewModel.clearSegments()

        XCTAssertTrue(viewModel.segments.isEmpty)
        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("字幕流已清空") })
        XCTAssertEqual(provider.stopCalls, 0)
        XCTAssertTrue(viewModel.isRunning)

        provider.emit(.segment(.fixture(id: 2, sourceText: "world", translatedText: "世界", isFinal: true)))
        let didReceiveNextSegment = await waitUntil {
            viewModel.segments.count == 1 && viewModel.segments.first?.id == 2
        }

        XCTAssertTrue(didReceiveNextSegment)
        XCTAssertEqual(viewModel.segments.first?.translatedText, "世界")
    }

    func testStopClosesCaptureAndIgnoresLateEvents() async {
        let provider = StubLiveMeetingCaptionProvider()
        let capture = StubLiveMeetingAudioCapture()
        let viewModel = makeViewModel(provider: provider, capture: capture)

        await viewModel.start()
        provider.emit(.segment(.fixture(id: 1, sourceText: "hello", translatedText: "你好", isFinal: true)))
        _ = await waitUntil { viewModel.segments.count == 1 }

        await viewModel.stop()
        provider.emit(.segment(.fixture(id: 2, sourceText: "late", translatedText: "迟到", isFinal: true)))
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertEqual(provider.stopCalls, 1)
        XCTAssertEqual(viewModel.segments.map(\.id), [1])
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testCapturedAudioIsSentToProvider() async {
        let provider = StubLiveMeetingCaptionProvider()
        let capture = StubLiveMeetingAudioCapture()
        let viewModel = makeViewModel(provider: provider, capture: capture)

        await viewModel.start()
        let frame = Data(repeating: 1, count: 6_400)
        capture.emit(frame)
        let didSendAudio = await waitUntil { provider.audioFrames == [frame] }

        XCTAssertTrue(didSendAudio)
    }

    func testCapturedAudioFlowWritesDiagnosticLogs() async {
        let provider = StubLiveMeetingCaptionProvider()
        let capture = StubLiveMeetingAudioCapture()
        let viewModel = makeViewModel(provider: provider, capture: capture)

        await viewModel.start()
        capture.emit(Data(repeating: 1, count: 3_200))
        capture.emit(Data(repeating: 2, count: 3_200))
        let didSendAudio = await waitUntil { provider.audioFrames.count == 1 }

        XCTAssertTrue(didSendAudio)
        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("采集音频帧 #1") })
        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("pendingBefore=3200") })
        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("音频切片：生成 1 个 chunk") })
        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("已发送音频 chunk #1") })
    }

    func testMixedLanguageTranslationDoesNotEnterSubtitleList() async {
        let provider = StubLiveMeetingCaptionProvider()
        let viewModel = makeViewModel(provider: provider)

        await viewModel.start()
        provider.emit(.segment(.fixture(id: 3, sourceText: "السلام عليكم", translatedText: "Hello mixed 混合", isFinal: true)))

        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("丢弃字幕 #3") })
        XCTAssertTrue(viewModel.segments.isEmpty)
    }

    func testArabicPartialDoesNotEnterSubtitleList() async {
        let provider = StubLiveMeetingCaptionProvider()
        let viewModel = makeViewModel(provider: provider)
        viewModel.targetLanguage = .arabic

        await viewModel.start()
        provider.emit(.segment(.fixture(id: 4, sourceText: "مرحبا", translatedText: "أهلاً", isFinal: false)))
        provider.emit(.segment(.fixture(id: 4, sourceText: "مرحبا", translatedText: "أهلاً وسهلاً", isFinal: true)))

        let didReceiveFinal = await waitUntil {
            viewModel.segments.count == 1 && viewModel.segments.first?.translatedText == "أهلاً وسهلاً"
        }

        XCTAssertTrue(didReceiveFinal)
    }

    func testChangingTargetLanguageWhileRunningRestartsSession() async {
        let provider = StubLiveMeetingCaptionProvider()
        let capture = StubLiveMeetingAudioCapture()
        let viewModel = makeViewModel(provider: provider, capture: capture)

        await viewModel.start()
        provider.emit(.started)
        _ = await waitUntil { viewModel.state == .streaming }

        viewModel.targetLanguage = .arabic
        let didRestart = await waitUntil {
            provider.startCalls.count == 2 && provider.startCalls.last?.targetLanguage == .arabic
        }

        XCTAssertTrue(didRestart)
        XCTAssertEqual(provider.stopCalls, 1)
        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("切换目标语言：阿语") })
        XCTAssertTrue(viewModel.logs.contains { $0.message.contains("to=ar (阿语)") })
    }

    private func makeViewModel(
        provider: StubLiveMeetingCaptionProvider,
        capture: StubLiveMeetingAudioCapture = StubLiveMeetingAudioCapture(),
        credentials: LiveMeetingCaptionCredentials = LiveMeetingCaptionCredentials(subscriptionKey: "key", region: "eastus")
    ) -> RealTimeMeetingCaptionViewModel {
        RealTimeMeetingCaptionViewModel(
            preferences: InMemoryLiveMeetingCaptionPreferences(),
            credentialsProvider: { credentials },
            providerFactory: { _ in provider },
            audioCapture: capture
        )
    }
}

private final class InMemoryLiveMeetingCaptionPreferences: LiveMeetingCaptionPreferencesProviding {
    var targetLanguage: RealTimeMeetingCaptionLanguage = .chineseSimplified
    var subtitleRetentionCount: Int = 20
    var chunkDurationMS: Int = 200
}

private final class StubLiveMeetingCaptionProvider: LiveMeetingCaptionProviding, @unchecked Sendable {
    private(set) var startCalls: [LiveMeetingCaptionSessionConfiguration] = []
    private(set) var audioFrames: [Data] = []
    private(set) var stopCalls = 0
    private var continuation: AsyncStream<RealTimeMeetingCaptionEvent>.Continuation?

    func start(configuration: LiveMeetingCaptionSessionConfiguration) async throws -> AsyncStream<RealTimeMeetingCaptionEvent> {
        startCalls.append(configuration)
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func sendAudioFrame(_ data: Data) async throws {
        audioFrames.append(data)
    }

    func stop() async {
        stopCalls += 1
        continuation?.finish()
    }

    func emit(_ event: RealTimeMeetingCaptionEvent) {
        continuation?.yield(event)
    }
}

private final class StubLiveMeetingAudioCapture: LiveMeetingAudioCapturing, @unchecked Sendable {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private var frameHandler: (@Sendable (Data) -> Void)?

    func start(frameHandler: @escaping @Sendable (Data) -> Void) async throws {
        startCalls += 1
        self.frameHandler = frameHandler
    }

    func stop() async {
        stopCalls += 1
        frameHandler = nil
    }

    func emit(_ data: Data) {
        frameHandler?(data)
    }
}

private extension RealTimeMeetingCaptionSegment {
    static func fixture(
        id: Int,
        sourceText: String,
        translatedText: String,
        isFinal: Bool
    ) -> Self {
        RealTimeMeetingCaptionSegment(
            id: id,
            sourceText: sourceText,
            translatedText: translatedText,
            isFinal: isFinal,
            startMilliseconds: id * 1_000,
            endMilliseconds: id * 1_000 + 800,
            lastUpdatedAt: Date(timeIntervalSince1970: TimeInterval(id))
        )
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 1.0,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
