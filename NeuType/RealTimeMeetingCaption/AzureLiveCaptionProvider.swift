import Foundation
import MicrosoftCognitiveServicesSpeech

enum AzureLiveCaptionProviderConfiguration {
    static let autoDetectSourceLanguageCodes = RealTimeMeetingCaptionLanguage.azureAutoDetectSourceLanguageCodes
}

final class AzureLiveCaptionProvider: LiveMeetingCaptionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var pushStream: SPXPushAudioInputStream?
    private var recognizer: SPXTranslationRecognizer?
    private var streamContinuation: AsyncStream<RealTimeMeetingCaptionEvent>.Continuation?
    private var isFinished = false
    private var segmentSequence = 0
    private var targetLanguage: RealTimeMeetingCaptionLanguage?

    func start(configuration: LiveMeetingCaptionSessionConfiguration) async throws -> AsyncStream<RealTimeMeetingCaptionEvent> {
        await stop()

        guard configuration.credentials.isConfigured else {
            throw LiveMeetingCaptionError.missingCredentials
        }

        let stream = AsyncStream<RealTimeMeetingCaptionEvent> { continuation in
            self.lock.lock()
            self.streamContinuation = continuation
            self.isFinished = false
            self.segmentSequence = 0
            self.targetLanguage = configuration.targetLanguage
            self.lock.unlock()
        }

        let recognizer = try makeRecognizer(configuration: configuration)
        wireEvents(recognizer: recognizer, targetLanguage: configuration.targetLanguage)

        lock.lock()
        self.recognizer = recognizer
        lock.unlock()

        try recognizer.startContinuousRecognition()

        return stream
    }

    func sendAudioFrame(_ data: Data) async throws {
        guard let pushStream = currentPushStream() else {
            throw LiveMeetingCaptionError.providerNotStarted
        }

        pushStream.write(data)
    }

    func stop() async {
        let recognizer: SPXTranslationRecognizer?
        let pushStream: SPXPushAudioInputStream?

        lock.lock()
        recognizer = self.recognizer
        pushStream = self.pushStream
        self.recognizer = nil
        self.pushStream = nil
        self.targetLanguage = nil
        lock.unlock()

        pushStream?.close()

        if let recognizer {
            try? recognizer.stopContinuousRecognition()
        }

        finishStream()
    }

    private func makeRecognizer(configuration: LiveMeetingCaptionSessionConfiguration) throws -> SPXTranslationRecognizer {
        let speechConfiguration = try SPXSpeechTranslationConfiguration(
            subscription: configuration.credentials.trimmedSubscriptionKey,
            region: configuration.credentials.trimmedRegion
        )

        if let languageIdMode = SPXPropertyId(rawValue: 3205) {
            speechConfiguration.setPropertyTo("Continuous", by: languageIdMode)
        }
        speechConfiguration.addTargetLanguage(configuration.targetLanguage.azureTargetLanguageCode)
        speechConfiguration.outputFormat = SPXOutputFormat.detailed

        let autoDetect = try SPXAutoDetectSourceLanguageConfiguration(
            AzureLiveCaptionProviderConfiguration.autoDetectSourceLanguageCodes
        )

        guard let format = SPXAudioStreamFormat(
            usingPCMWithSampleRate: 16_000,
            bitsPerSample: 16,
            channels: 1
        ) else {
            throw LiveMeetingCaptionError.serviceError("无法创建 Azure PCM 音频格式。")
        }
        guard let pushStream = SPXPushAudioInputStream(audioFormat: format) else {
            throw LiveMeetingCaptionError.serviceError("无法创建 Azure 音频输入流。")
        }
        guard let audioConfiguration = SPXAudioConfiguration(streamInput: pushStream) else {
            throw LiveMeetingCaptionError.serviceError("无法创建 Azure 音频配置。")
        }

        let recognizer = try SPXTranslationRecognizer(
            speechTranslationConfiguration: speechConfiguration,
            autoDetectSourceLanguageConfiguration: autoDetect,
            audioConfiguration: audioConfiguration
        )

        lock.lock()
        self.pushStream = pushStream
        lock.unlock()

        return recognizer
    }

    private func wireEvents(
        recognizer: SPXTranslationRecognizer,
        targetLanguage: RealTimeMeetingCaptionLanguage
    ) {
        recognizer.addSessionStartedEventHandler { [weak self] _, event in
            RequestLogStore.log(.usage, "Azure live captions session started: \(event.sessionId)")
            self?.yield(.started)
        }

        recognizer.addRecognizingEventHandler { [weak self] _, event in
            self?.handle(result: event.result, isFinal: false, targetLanguage: targetLanguage)
        }

        recognizer.addRecognizedEventHandler { [weak self] _, event in
            self?.handle(result: event.result, isFinal: true, targetLanguage: targetLanguage)
        }

        recognizer.addCanceledEventHandler { [weak self] _, event in
            let message = event.errorDetails?.isEmpty == false
                ? event.errorDetails ?? "Azure Speech Translation 已取消。"
                : "Azure Speech Translation 已取消。"
            RequestLogStore.log(.usage, "Azure live captions canceled: reason=\(event.reason.rawValue) code=\(event.errorCode.rawValue) details=\(message)")
            self?.yield(.error(message: "Azure Speech Translation 错误：\(message)"))
            self?.finishStream()
        }

        recognizer.addSessionStoppedEventHandler { [weak self] _, event in
            RequestLogStore.log(.usage, "Azure live captions session stopped: \(event.sessionId)")
            self?.finishStream()
        }
    }

    private func handle(
        result: SPXTranslationRecognitionResult,
        isFinal: Bool,
        targetLanguage: RealTimeMeetingCaptionLanguage
    ) {
        guard result.reason == SPXResultReason.translatingSpeech || result.reason == SPXResultReason.translatedSpeech else {
            return
        }

        let sourceLanguage = SPXAutoDetectSourceLanguageResult(result).language ?? ""
        let translation = translationText(from: result, targetLanguage: targetLanguage)
        let sourceText = result.text ?? ""
        let nextID = nextSegmentID(for: result)

        RequestLogStore.log(
            .usage,
            "Azure live captions \(isFinal ? "final" : "partial") id=\(nextID) sourceLang=\(sourceLanguage) target=\(targetLanguage.azureTargetLanguageCode) source=\"\(sourceText)\" translation=\"\(translation)\""
        )

        guard LiveCaptionLanguageValidator.isDisplayable(translation, as: targetLanguage) else {
            RequestLogStore.log(
                .usage,
                "Azure live captions dropped id=\(nextID): translation does not match target \(targetLanguage.displayName)"
            )
            return
        }

        let segment = RealTimeMeetingCaptionSegment(
            id: nextID,
            sourceText: sourceText,
            translatedText: translation,
            isFinal: isFinal,
            targetLanguage: targetLanguage,
            startMilliseconds: Int(result.offset / 10_000),
            endMilliseconds: Int((result.offset + result.duration) / 10_000),
            lastUpdatedAt: Date()
        )
        yield(.segment(segment))
    }

    private func translationText(
        from result: SPXTranslationRecognitionResult,
        targetLanguage: RealTimeMeetingCaptionLanguage
    ) -> String {
        let translations = result.translations as? [String: String] ?? [:]
        return translations[targetLanguage.azureTargetLanguageCode]
            ?? translations[targetLanguage.azureTargetLanguageCode.lowercased()]
            ?? translations.values.first
            ?? ""
    }

    private func nextSegmentID(for result: SPXTranslationRecognitionResult) -> Int {
        let offsetID = Int(result.offset / 10_000)
        if offsetID > 0 {
            return offsetID
        }

        lock.lock()
        defer { lock.unlock() }
        segmentSequence += 1
        return segmentSequence
    }

    private func currentPushStream() -> SPXPushAudioInputStream? {
        lock.lock()
        defer { lock.unlock() }
        return pushStream
    }

    private func yield(_ event: RealTimeMeetingCaptionEvent) {
        lock.lock()
        let continuation = streamContinuation
        let finished = isFinished
        lock.unlock()

        guard !finished else { return }
        continuation?.yield(event)
    }

    private func finishStream() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = streamContinuation
        streamContinuation = nil
        lock.unlock()

        continuation?.finish()
    }
}
