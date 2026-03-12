import Foundation

private struct GroqTranscriptionResponse: Decodable {
    let text: String?
}

private enum GroqASRAPI {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let model = "whisper-large-v3"
}

class WhisperEngine: TranscriptionEngine {
    var engineName: String { "Groq Whisper" }

    var isModelLoaded: Bool {
        !AppPreferences.shared.deepInfraAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var onProgressUpdate: ((Float) -> Void)?

    func initialize() async throws {
        guard isModelLoaded else {
            throw TranscriptionError.contextInitializationFailed
        }
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        print("Groq ASR request: \(GroqASRAPI.endpoint.absoluteString), file=\(url.lastPathComponent)")
        onProgressUpdate?(0.05)

        let audioData = try Data(contentsOf: url)
        onProgressUpdate?(0.20)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: GroqASRAPI.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(AppPreferences.shared.deepInfraAPIKey)",
            forHTTPHeaderField: "Authorization"
        )

        request.httpBody = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            filename: url.lastPathComponent,
            settings: settings
        )

        onProgressUpdate?(0.45)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.processingFailed
        }

        onProgressUpdate?(0.85)
        print("Groq ASR response status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown server error"
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
                apiKey: AppPreferences.shared.deepInfraAPIKey
            )
        }

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
        settings: Settings
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
        body.append("\(GroqASRAPI.model)\(lineBreak)")

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
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
