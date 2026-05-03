import Foundation

final class YoudaoLiveCaptionProvider: LiveMeetingCaptionProviding, @unchecked Sendable {
    private let session: URLSession
    private let urlBuilder: YoudaoLiveCaptionURLBuilder
    private let dateProvider: @Sendable () -> Date
    private let saltProvider: @Sendable () -> String

    private let lock = NSLock()
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<RealTimeMeetingCaptionEvent>.Continuation?
    private var isFinished = false
    private var targetLanguage: RealTimeMeetingCaptionLanguage?

    init(
        session: URLSession = .shared,
        urlBuilder: YoudaoLiveCaptionURLBuilder = YoudaoLiveCaptionURLBuilder(),
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        saltProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.session = session
        self.urlBuilder = urlBuilder
        self.dateProvider = dateProvider
        self.saltProvider = saltProvider
    }

    func start(configuration: LiveMeetingCaptionSessionConfiguration) async throws -> AsyncStream<RealTimeMeetingCaptionEvent> {
        await stop()

        guard configuration.credentials.isConfigured else {
            throw LiveMeetingCaptionError.missingCredentials
        }

        let currentTime = String(Int(dateProvider().timeIntervalSince1970))
        setTargetLanguage(configuration.targetLanguage)
        let url = try urlBuilder.makeURL(
            credentials: configuration.credentials,
            targetLanguage: configuration.targetLanguage,
            salt: saltProvider(),
            currentTime: currentTime
        )

        let stream = AsyncStream<RealTimeMeetingCaptionEvent> { continuation in
            self.lock.lock()
            self.streamContinuation = continuation
            self.isFinished = false
            self.lock.unlock()
        }

        let request = URLRequest(url: url)
        let socketTask = session.webSocketTask(with: request)
        self.lock.lock()
        self.socketTask = socketTask
        self.lock.unlock()

        socketTask.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        return stream
    }

    func sendAudioFrame(_ data: Data) async throws {
        guard let socketTask = currentSocketTask() else {
            throw LiveMeetingCaptionError.providerNotStarted
        }

        do {
            try await socketTask.send(.data(data))
        } catch {
            throw LiveMeetingCaptionError.sendFailed(error.localizedDescription)
        }
    }

    func stop() async {
        let socketTask = currentSocketTask()
        clearReceiveTask()

        if let socketTask {
            try? await socketTask.send(.data(Data(#"{"end":"true"}"#.utf8)))
            socketTask.cancel(with: .goingAway, reason: nil)
        }

        finishStream()
    }

    private func receiveLoop() async {
        guard let socketTask = currentSocketTask() else {
            finishStream()
            return
        }

        do {
            while !Task.isCancelled {
                let message = try await socketTask.receive()
                let text: String?
                switch message {
                case .string(let string):
                    text = string
                case .data(let data):
                    text = String(data: data, encoding: .utf8)
                @unknown default:
                    text = nil
                }

                guard let text else { continue }
                RequestLogStore.log(.usage, "Live captions Youdao raw response: \(Self.redactedPreview(text))")
                guard let parsed = YoudaoLiveCaptionResponseParser.parseMessage(text, targetLanguage: currentTargetLanguage()) else {
                    RequestLogStore.log(.usage, "Live captions ignored unparsed Youdao response")
                    continue
                }

                yield(parsed.event)
                if parsed.shouldFinish {
                    finishStream()
                    return
                }
            }
        } catch {
            yield(.error(message: LiveMeetingCaptionError.networkFailed(error.localizedDescription).localizedDescription))
        }

        finishStream()
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

    private func currentSocketTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return socketTask
    }

    private func currentTargetLanguage() -> RealTimeMeetingCaptionLanguage? {
        lock.lock()
        defer { lock.unlock() }
        return targetLanguage
    }

    private func setTargetLanguage(_ language: RealTimeMeetingCaptionLanguage) {
        lock.lock()
        targetLanguage = language
        lock.unlock()
    }

    private func clearReceiveTask() {
        lock.lock()
        let task = receiveTask
        receiveTask = nil
        socketTask = nil
        targetLanguage = nil
        lock.unlock()
        task?.cancel()
    }

    private static func redactedPreview(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if compact.count <= 1_200 {
            return compact
        }
        return String(compact.prefix(1_200)) + "..."
    }
}
