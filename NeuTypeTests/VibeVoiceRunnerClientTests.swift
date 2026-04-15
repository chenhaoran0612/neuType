import Foundation
import XCTest
@testable import NeuType

final class VibeVoiceRunnerClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        URLProtocolStub.requestHandlers = []
        URLProtocolStub.recordedRequests = []
    }

    func testTranscribeUploadsAudioQueuesJobAndParsesSpeakerSegments() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("demo-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "http://workspace.featurize.cn:12930",
                apiPrefix: "/gradio_api",
                contextInfo: "OpenAI\nMicrosoft",
                maxNewTokens: 4096,
                temperature: 0.0,
                topP: 1.0,
                doSample: false,
                repetitionPenalty: 1.0
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"["/tmp/gradio/uploaded.wav"]"#.data(using: .utf8)!
                )
            },
            { request in
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"dependencies":[{"api_name":"lambda","id":0},{"api_name":"transcribe_audio","id":2}]}"#.data(using: .utf8)!
                )
            },
            { request in
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    #"{"event_id":"evt-123"}"#.data(using: .utf8)!
                )
            },
            { request in
                let sse = """
                data: {"msg":"estimation","event_id":"evt-123","rank":0,"queue_size":1}

                data: {"msg":"process_starts","event_id":"evt-123","eta":1.2}

                data: {"msg":"process_generating","event_id":"evt-123","output":{"data":["partial","<div>loading</div>"],"is_generating":true},"success":true}

                data: {"msg":"process_completed","event_id":"evt-123","output":{"data":["📥 Input: 203 tokens\\nassistant\\n[{\\"Start\\":0,\\"End\\":1.5,\\"Speaker\\":0,\\"Content\\":\\"hello\\"},{\\"Start\\":1.5,\\"End\\":3.0,\\"Speaker\\":1,\\"Content\\":\\"world\\"}]","<div>done</div>"]},"success":true}

                """
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!,
                    Data(sse.utf8)
                )
            },
        ]

        let client = VibeVoiceRunnerClient(
            session: session,
            configProvider: config
        )

        let result = try await client.transcribe(audioURL: audioURL, hotwords: ["VibeVoice"])

        XCTAssertEqual(result.fullText, "hello world")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(result.segments[1].speakerLabel, "Speaker 2")

        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 4)

        let uploadRequest = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 0])
        XCTAssertEqual(uploadRequest.url?.path, "/gradio_api/upload")
        XCTAssertEqual(uploadRequest.httpMethod, "POST")
        XCTAssertEqual(uploadRequest.timeoutInterval, 1800)

        let uploadBody = try XCTUnwrap(
            uploadRequest.httpBody ?? uploadRequest.httpBodyStream.flatMap(Self.readStream)
        )
        let uploadBodyString = String(decoding: uploadBody, as: UTF8.self)
        XCTAssertTrue(uploadBodyString.contains("filename=\"\(audioURL.lastPathComponent)\""))

        let configRequest = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 1])
        XCTAssertEqual(configRequest.url?.path, "/config")
        XCTAssertEqual(configRequest.httpMethod, "GET")
        XCTAssertEqual(configRequest.timeoutInterval, 60)

        let joinRequest = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 2])
        XCTAssertEqual(joinRequest.url?.path, "/gradio_api/queue/join")
        XCTAssertEqual(joinRequest.httpMethod, "POST")
        XCTAssertEqual(joinRequest.timeoutInterval, 1800)
        let joinBody = try XCTUnwrap(
            joinRequest.httpBody ?? joinRequest.httpBodyStream.flatMap(Self.readStream)
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: joinBody) as? [String: Any])
        let callData = try XCTUnwrap(payload["data"] as? [Any])
        let audioInput = try XCTUnwrap(callData[0] as? [String: Any])
        XCTAssertEqual(audioInput["path"] as? String, "/tmp/gradio/uploaded.wav")
        XCTAssertEqual(audioInput["orig_name"] as? String, audioURL.lastPathComponent)
        XCTAssertEqual(callData[9] as? String, "OpenAI\nMicrosoft\nVibeVoice")
        XCTAssertEqual(payload["fn_index"] as? Int, 2)
        XCTAssertNotNil(payload["session_hash"] as? String)

        let eventsRequest = try XCTUnwrap(URLProtocolStub.recordedRequests[safe: 3])
        XCTAssertEqual(eventsRequest.url?.path, "/gradio_api/queue/data")
        XCTAssertEqual(eventsRequest.url?.query?.contains("session_hash="), true)
        XCTAssertEqual(eventsRequest.timeoutInterval, 3600)
    }

    func testDecodeResultFailsWhenAssistantJSONMissing() {
        XCTAssertThrowsError(
            try VibeVoiceRunnerClient.decodeResult(
                from: "assistant\nnot-json".data(using: .utf8)!
            )
        )
    }

    func testDecodeResultParsesOnlyBalancedJSONArray() throws {
        let payload = """
        --- ✅ Raw Output ---
        assistant
        [{"Start":0.0,"End":1.5,"Speaker":0,"Content":"hello"}]
        <div>ignored</div>
        """.data(using: .utf8)!

        let result = try VibeVoiceRunnerClient.decodeResult(from: payload)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.fullText, "hello")
    }

    func testDecodeResultReturnsServiceNoSegmentsError() {
        let payload = """
        --- ✅ Raw Output ---
        assistant
        [Click] [Click]

        <div class='no-segments-container'>
            <p>❌ No audio segments available.</p>
            <p>This could happen if the model output doesn't contain valid time stamps.</p>
        </div>
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try VibeVoiceRunnerClient.decodeResult(from: payload)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "No audio segments available. This could happen if the model output doesn't contain valid time stamps."
            )
        }
    }

    func testExtractQueuedRawTextSupportsTerminalPatchPayload() {
        let sse = """
        data: {"msg":"process_generating","event_id":"evt-456","output":{"data":[[[\"replace\",[],\"--- ✅ Raw Output ---\\nassistant\\n[{\\\"Start\\\":0.0,\\\"End\\\":4.22,\\\"Speaker\\\":0,\\\"Content\\\":\\\"hello world\\\"}]\\n\"]],[[\"replace\",[],\"<div>done</div>\"]]],\"is_generating\":false},\"success\":true}

        """

        let rawText = VibeVoiceRunnerClient.extractQueuedRawText(from: Data(sse.utf8), eventID: "evt-456")
        XCTAssertEqual(
            rawText,
            """
            --- ✅ Raw Output ---
            assistant
            [{"Start":0.0,"End":4.22,"Speaker":0,"Content":"hello world"}]
            """
        )
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func readStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }

        return data
    }
}

private struct StubMeetingVibeVoiceConfigProvider: MeetingVibeVoiceConfigProviding {
    let config: MeetingVibeVoiceConfig

    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig { config }
}

private final class URLProtocolStub: URLProtocol {
    static var requestHandlers: [(URLRequest) throws -> (HTTPURLResponse, Data)] = []
    static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recordedRequests.append(request)
        guard !Self.requestHandlers.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let handler = Self.requestHandlers.removeFirst()
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
