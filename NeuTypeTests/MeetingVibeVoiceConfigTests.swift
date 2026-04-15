import XCTest
@testable import NeuType

final class MeetingVibeVoiceConfigTests: XCTestCase {
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
}
