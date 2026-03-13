import Foundation

private struct GroqTranscriptionResponse: Decodable {
    let text: String?
}

class WhisperEngine: TranscriptionEngine {
    var engineName: String { "OpenAI-Compatible ASR" }

    var isModelLoaded: Bool {
        !resolvedASRAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var onProgressUpdate: ((Float) -> Void)?

    func initialize() async throws {
        guard isModelLoaded else {
            throw TranscriptionError.contextInitializationFailed
        }
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        let endpoint = resolvedEndpoint(from: AppPreferences.shared.asrAPIBaseURL, path: "/audio/transcriptions")
        let configuredModel = AppPreferences.shared.asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrModel = configuredModel.isEmpty ? "whisper-large-v3" : configuredModel
        RequestLogStore.log(
            .asr,
            "Request -> endpoint=\(endpoint.absoluteString), model=\(asrModel), file=\(url.lastPathComponent), language=\(settings.selectedLanguage), temp=\(settings.temperature)"
        )
        onProgressUpdate?(0.05)

        let audioData = try Data(contentsOf: url)
        onProgressUpdate?(0.20)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(resolvedASRAPIKey())",
            forHTTPHeaderField: "Authorization"
        )

        request.httpBody = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            filename: url.lastPathComponent,
            settings: settings,
            model: asrModel
        )

        onProgressUpdate?(0.45)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.processingFailed
        }

        onProgressUpdate?(0.85)
        RequestLogStore.log(.asr, "Response <- status=\(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown server error"
            RequestLogStore.log(.asr, "Error <- status=\(httpResponse.statusCode), body=\(body)")
            throw NSError(
                domain: "GroqWhisper",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: body]
            )
        }

        let decoder = JSONDecoder()
        let result = try decoder.decode(GroqTranscriptionResponse.self, from: data)
        let rawText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var processedText = rawText
        if settings.shouldApplyAsianAutocorrect && !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }

        if settings.removeDisfluency && !processedText.isEmpty {
            processedText = await DisfluencyCleaner.clean(
                text: processedText,
                languageCode: settings.selectedLanguage,
                apiKey: AppPreferences.shared.llmAPIKey
            )
        }

        RequestLogStore.log(.asr, "Parsed <- transcriptLength=\(processedText.count)")
        RequestLogStore.log(.asr, "Final <- \(processedText.replacingOccurrences(of: "\n", with: "\\n"))")

        onProgressUpdate?(1.0)

        return processedText.isEmpty ? "No speech detected in the audio" : processedText
    }

    func cancelTranscription() {
    }

    func getSupportedLanguages() -> [String] {
        LanguageUtil.availableLanguages
    }

    private func makeMultipartBody(
        boundary: String,
        audioData: Data,
        filename: String,
        settings: Settings,
        model: String
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lineBreak)")
        body.append("Content-Type: audio/wav\(lineBreak)\(lineBreak)")
        body.append(audioData)
        body.append(lineBreak)

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"model\"\(lineBreak)\(lineBreak)")
        body.append("\(model)\(lineBreak)")

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"temperature\"\(lineBreak)\(lineBreak)")
        let temperatureString = String(format: "%.2f", settings.temperature)
        body.append("\(temperatureString)\(lineBreak)")

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"response_format\"\(lineBreak)\(lineBreak)")
        body.append("verbose_json\(lineBreak)")

        if settings.selectedLanguage != "auto" {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"language\"\(lineBreak)\(lineBreak)")
            body.append("\(settings.selectedLanguage)\(lineBreak)")
        }

        if !settings.initialPrompt.isEmpty {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"prompt\"\(lineBreak)\(lineBreak)")
            body.append("\(settings.initialPrompt)\(lineBreak)")
        }

        body.append("--\(boundary)--\(lineBreak)")
        return body
    }

    private func resolvedEndpoint(from base: String, path: String) -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let asURL = URL(string: trimmed), asURL.path.hasSuffix("/\(normalizedPath)") {
            return asURL
        }
        if let baseURL = URL(string: trimmed) {
            return baseURL.appendingPathComponent(normalizedPath)
        }

        return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    }

    private func resolvedASRAPIKey() -> String {
        let configured = AppPreferences.shared.asrAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return AppPreferences.shared.groqAPIKey
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
