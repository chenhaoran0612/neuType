import Foundation

private struct DeepInfraChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case enableThinking = "enable_thinking"
    }
}

private struct DeepInfraChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

enum DisfluencyCleaner {
    private static let endpoint = URL(string: "https://api.deepinfra.com/v1/openai/chat/completions")!
    private static let model = "Qwen/Qwen3-14B"

    static func clean(text: String, languageCode: String, apiKey: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let systemPrompt = "You are a transcription post-processor. Remove filler words, disfluencies, repetitions, and stutters while preserving meaning, tone, and language. Keep punctuation natural. Return only the cleaned text."
        let userPrompt = "Language code: \(languageCode).\nOriginal transcript:\n\(trimmed)"

        let payload = DeepInfraChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.0,
            enableThinking: false
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return text
            }

            let result = try JSONDecoder().decode(DeepInfraChatResponse.self, from: data)
            let content = result.choices.first?.message.content ?? ""
            let cleaned = sanitizeModelOutput(content).trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? text : cleaned
        } catch {
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
}
