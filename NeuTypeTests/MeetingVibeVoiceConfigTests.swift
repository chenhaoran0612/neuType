import XCTest
@testable import NeuType

final class MeetingVibeVoiceConfigTests: XCTestCase {
    func testDefaultMeetingTranscriptionBaseURLUsesDeployedService() {
        let preferences = AppPreferences.shared
        let previousBaseURL = preferences.meetingVibeVoiceBaseURL
        defer {
            preferences.meetingVibeVoiceBaseURL = previousBaseURL
        }

        UserDefaults.standard.removeObject(forKey: "meetingVibeVoiceBaseURL")

        XCTAssertEqual(
            preferences.meetingVibeVoiceBaseURL,
            "https://meeting-transcription.neuxnet.com"
        )
    }

    func testResolvedCallURLUsesBaseURLAndAPIPrefix() {
        let config = MeetingVibeVoiceConfig(
            baseURL: "http://workspace.featurize.cn:12930",
            apiPrefix: "/gradio_api",
            contextInfo: "OpenAI\nMicrosoft",
            maxNewTokens: 16384,
            temperature: 0.0,
            topP: 1.0,
            doSample: false,
            repetitionPenalty: 1.0
        )

        XCTAssertEqual(
            config.endpointURL(path: "call/transcribe_audio")?.absoluteString,
            "http://workspace.featurize.cn:12930/gradio_api/call/transcribe_audio"
        )
    }

    func testResolvedCallURLHandlesTrailingSlashes() {
        let config = MeetingVibeVoiceConfig(
            baseURL: "http://workspace.featurize.cn:12930/",
            apiPrefix: "gradio_api/",
            contextInfo: "",
            maxNewTokens: 16384,
            temperature: 0.0,
            topP: 1.0,
            doSample: false,
            repetitionPenalty: 1.0
        )

        XCTAssertEqual(
            config.endpointURL(path: "/upload")?.absoluteString,
            "http://workspace.featurize.cn:12930/gradio_api/upload"
        )
    }

    func testChatCompletionsURLIgnoresLegacyGradioPrefix() {
        let config = MeetingVibeVoiceConfig(
            baseURL: "http://workspace.featurize.cn:12930",
            apiPrefix: "/gradio_api",
            contextInfo: "",
            maxNewTokens: 2048,
            temperature: 0.0,
            topP: 1.0,
            doSample: false,
            repetitionPenalty: 1.0
        )

        XCTAssertEqual(
            config.chatCompletionsURL()?.absoluteString,
            "http://workspace.featurize.cn:12930/v1/chat/completions"
        )
    }

    func testChatCompletionsURLUsesCustomPrefixWhenProvided() {
        let config = MeetingVibeVoiceConfig(
            baseURL: "http://workspace.featurize.cn:12930",
            apiPrefix: "/proxy",
            contextInfo: "",
            maxNewTokens: 2048,
            temperature: 0.0,
            topP: 1.0,
            doSample: false,
            repetitionPenalty: 1.0
        )

        XCTAssertEqual(
            config.chatCompletionsURL()?.absoluteString,
            "http://workspace.featurize.cn:12930/proxy/v1/chat/completions"
        )
    }

    func testChatCompletionsURLAcceptsFullEndpointBaseURL() {
        let config = MeetingVibeVoiceConfig(
            baseURL: "https://tokenhubpro.com/v1/chat/completions",
            apiPrefix: "",
            contextInfo: "",
            maxNewTokens: 2048,
            temperature: 0.0,
            topP: 1.0,
            doSample: false,
            repetitionPenalty: 1.0
        )

        XCTAssertEqual(
            config.chatCompletionsURL()?.absoluteString,
            "https://tokenhubpro.com/v1/chat/completions"
        )
    }

    func testCombinedContextMergesConfiguredTermsAndHotwords() {
        let config = MeetingVibeVoiceConfig(
            baseURL: "http://workspace.featurize.cn:12930",
            apiPrefix: "/gradio_api",
            contextInfo: "OpenAI\nMicrosoft",
            maxNewTokens: 16384,
            temperature: 0.0,
            topP: 1.0,
            doSample: false,
            repetitionPenalty: 1.0
        )

        XCTAssertEqual(
            config.combinedContextInfo(hotwords: ["VibeVoice", "Microsoft"]),
            "OpenAI\nMicrosoft\nVibeVoice"
        )
    }

    func testTrimmedAPIKeyRemovesWhitespace() {
        let config = MeetingVibeVoiceConfig(
            baseURL: "http://workspace.featurize.cn:12930",
            apiPrefix: "",
            apiKey: "  vv_test_key\n",
            contextInfo: "",
            maxNewTokens: 2048,
            temperature: 0.0,
            topP: 1.0,
            doSample: false,
            repetitionPenalty: 1.0
        )

        XCTAssertEqual(config.trimmedAPIKey, "vv_test_key")
    }
}
