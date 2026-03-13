import Foundation

private struct GroqChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxCompletionTokens: Int
    let topP: Double
    let stream: Bool
    let reasoningEffort: String
    let stop: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxCompletionTokens = "max_completion_tokens"
        case topP = "top_p"
        case stream
        case reasoningEffort = "reasoning_effort"
        case stop
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxCompletionTokens, forKey: .maxCompletionTokens)
        try container.encode(topP, forKey: .topP)
        try container.encode(stream, forKey: .stream)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        if let stop {
            try container.encode(stop, forKey: .stop)
        } else {
            try container.encodeNil(forKey: .stop)
        }
    }
}

private struct GroqChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct GroqChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        struct Message: Decodable {
            let content: String?
        }

        let delta: Delta?
        let message: Message?
    }

    let choices: [Choice]
}

enum DisfluencyCleaner {
    static func clean(text: String, languageCode: String, apiKey: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            RequestLogStore.log(.llm, "Final <- (skipped: empty input)")
            return text
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            RequestLogStore.log(.llm, "Final <- (skipped: missing LLM API key)")
            return text
        }
        let endpoint = resolvedEndpoint(from: AppPreferences.shared.llmAPIBaseURL, path: "/chat/completions")
        let configuredModel = AppPreferences.shared.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let llmModel = configuredModel.isEmpty ? "openai/gpt-oss-20b" : configuredModel
        let configuredPrompt = AppPreferences.shared.llmOptimizationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = configuredPrompt.isEmpty
            ? "You are an expert transcription editor. Improve clarity and readability while preserving the original meaning, intent, tone, and language. Remove filler words, stutters, and obvious disfluencies only when safe. Keep names, numbers, facts, and ordering unchanged. Fix punctuation and sentence boundaries so the text is easy to read and unambiguous. If the output text is Traditional Chinese, convert it to Simplified Chinese while preserving meaning and terminology. Do not add new information or reinterpret meaning. Return only the edited transcript text."
            : configuredPrompt

        RequestLogStore.log(
            .llm,
            "Request -> endpoint=\(endpoint.absoluteString), model=\(llmModel), language=\(languageCode), inputLength=\(trimmed.count), stream=true"
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let userPrompt = "Language code: \(languageCode).\nOriginal transcript:\n\(trimmed)"

        let payload = GroqChatRequest(
            model: llmModel,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.1,
            maxCompletionTokens: 8192,
            topP: 1.0,
            stream: true,
            reasoningEffort: "medium",
            stop: nil
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                if let httpResponse = response as? HTTPURLResponse {
                    RequestLogStore.log(.llm, "Error <- status=\(httpResponse.statusCode)")
                }
                RequestLogStore.log(.llm, "Final <- \(text.replacingOccurrences(of: "\n", with: "\\n"))")
                return text
            }

            RequestLogStore.log(.llm, "Response <- status=\(httpResponse.statusCode), stream=true")

            let decoder = JSONDecoder()
            var content = ""

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("data:") else { continue }

                let payloadLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payloadLine == "[DONE]" { break }
                guard let chunkData = payloadLine.data(using: .utf8) else { continue }

                if let chunk = try? decoder.decode(GroqChatStreamChunk.self, from: chunkData) {
                    for choice in chunk.choices {
                        if let piece = choice.delta?.content ?? choice.message?.content {
                            content += piece
                        }
                    }
                }
            }

            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RequestLogStore.log(.llm, "Fallback -> empty stream content, retrying non-stream")
                let fallbackPayload = GroqChatRequest(
                    model: llmModel,
                    messages: [
                        .init(role: "system", content: systemPrompt),
                        .init(role: "user", content: userPrompt)
                    ],
                    temperature: 0.1,
                    maxCompletionTokens: 8192,
                    topP: 1.0,
                    stream: false,
                    reasoningEffort: "medium",
                    stop: nil
                )

                var fallbackRequest = request
                fallbackRequest.httpBody = try JSONEncoder().encode(fallbackPayload)
                let (data, fallbackResponse) = try await URLSession.shared.data(for: fallbackRequest)
                guard let fallbackHTTPResponse = fallbackResponse as? HTTPURLResponse,
                      (200...299).contains(fallbackHTTPResponse.statusCode) else {
                    if let fallbackHTTPResponse = fallbackResponse as? HTTPURLResponse {
                        RequestLogStore.log(.llm, "Error <- fallback status=\(fallbackHTTPResponse.statusCode)")
                    }
                    RequestLogStore.log(.llm, "Final <- \(text.replacingOccurrences(of: "\n", with: "\\n"))")
                    return text
                }

                RequestLogStore.log(.llm, "Response <- fallback status=\(fallbackHTTPResponse.statusCode)")

                let result = try decoder.decode(GroqChatResponse.self, from: data)
                content = result.choices.first?.message.content ?? ""
            }

            let cleaned = sanitizeModelOutput(content).trimmingCharacters(in: .whitespacesAndNewlines)
            RequestLogStore.log(.llm, "Parsed <- outputLength=\(cleaned.count)")
            let finalLLMText = cleaned.isEmpty ? text : cleaned
            RequestLogStore.log(.llm, "Final <- \(finalLLMText.replacingOccurrences(of: "\n", with: "\\n"))")
            return cleaned.isEmpty ? text : cleaned
        } catch {
            RequestLogStore.log(.llm, "Error <- \(error.localizedDescription)")
            RequestLogStore.log(.llm, "Final <- \(text.replacingOccurrences(of: "\n", with: "\\n"))")
            return text
        }
    }

    private static func sanitizeModelOutput(_ text: String) -> String {
        var output = text
        output = removing(pattern: "(?is)<think>.*?</think>", in: output)
        output = removing(pattern: "(?is)<thinking>.*?</thinking>", in: output)
        return output
    }

    private static func removing(pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func resolvedEndpoint(from base: String, path: String) -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let asURL = URL(string: trimmed), asURL.path.hasSuffix("/\(normalizedPath)") {
            return asURL
        }
        if let baseURL = URL(string: trimmed) {
            return baseURL.appendingPathComponent(normalizedPath)
        }
        return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    }
}
