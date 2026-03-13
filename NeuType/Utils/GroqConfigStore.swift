import Foundation

struct GroqConfig: Codable {
    var apiKey: String
    var asrModel: String
    var llmModel: String

    init(
        apiKey: String = "",
        asrModel: String = "whisper-large-v3",
        llmModel: String = "openai/gpt-oss-20b"
    ) {
        self.apiKey = apiKey
        self.asrModel = asrModel
        self.llmModel = llmModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        asrModel =
            try container.decodeIfPresent(String.self, forKey: .asrModel)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .ocrModel)
            ?? "whisper-large-v3"
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? "openai/gpt-oss-20b"
    }

    enum CodingKeys: String, CodingKey {
        case apiKey
        case asrModel
        case llmModel
    }

    enum LegacyCodingKeys: String, CodingKey {
        case ocrModel
    }
}

enum GroqConfigStore {
    private static let directoryName = "OpenSuperWhisper"
    private static let fileName = "groq_config.json"

    static var configFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(fileName)
    }

    static func loadConfig() -> GroqConfig {
        let url = configFileURL
        guard let data = try? Data(contentsOf: url) else { return GroqConfig() }
        return (try? JSONDecoder().decode(GroqConfig.self, from: data)) ?? GroqConfig()
    }

    static func saveConfig(_ config: GroqConfig) {
        let url = configFileURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[GroqConfig] Failed to save config: \(error.localizedDescription)")
        }
    }

    static func loadAPIKey() -> String {
        loadConfig().apiKey
    }

    static func saveAPIKey(_ apiKey: String) {
        var config = loadConfig()
        config.apiKey = apiKey
        saveConfig(config)
    }
}
