import Foundation
import XCTest
@testable import NeuType

final class MeetingRemoteTranscriptionClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        URLProtocolStub.requestHandlers = []
        URLProtocolStub.recordedRequests = []
    }

    func testCreateSessionUsesConfigDerivedEndpointAndDecodesResponse() async throws {
        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "https://meeting.example.com/v1/chat/completions",
                apiPrefix: "",
                apiKey: "remote_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0,
                topP: 1,
                doSample: false,
                repetitionPenalty: 1
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                XCTAssertEqual(request.url?.absoluteString, "https://meeting.example.com/api/meeting-transcription/sessions")
                XCTAssertEqual(request.httpMethod, "POST")
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 201),
                    #"""
                    {"request_id":"req_create","data":{"session_id":"mts_123","status":"created","input_mode":"live_chunks","chunk_duration_ms":300000,"chunk_overlap_ms":2500},"error":null}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = MeetingRemoteTranscriptionClient(session: session, configProvider: config)
        let response = try await client.createSession(.fixture())

        XCTAssertEqual(response.sessionID, "mts_123")
        XCTAssertEqual(response.status, "created")
        XCTAssertEqual(response.inputMode, "live_chunks")
        XCTAssertEqual(response.chunkDurationMS, 300000)
        XCTAssertEqual(response.chunkOverlapMS, 2500)
    }

    func testCreateSessionAppliesAuthHeaders() async throws {
        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "https://meeting.example.com",
                apiPrefix: "",
                apiKey: "  remote_key  ",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0,
                topP: 1,
                doSample: false,
                repetitionPenalty: 1
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer remote_key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "remote_key")
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 201),
                    #"""
                    {"request_id":"req_auth","data":{"session_id":"mts_auth","status":"created","input_mode":"live_chunks","chunk_duration_ms":300000,"chunk_overlap_ms":2500},"error":null}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = MeetingRemoteTranscriptionClient(session: session, configProvider: config)
        _ = try await client.createSession(.fixture())

        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)
    }

    func testUploadChunkUsesMultipartFormDataAndServerFieldNames() async throws {
        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "https://meeting.example.com",
                apiPrefix: "",
                apiKey: "remote_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0,
                topP: 1,
                doSample: false,
                repetitionPenalty: 1
            )
        )

        let audioData = Data("chunk-audio".utf8)
        URLProtocolStub.requestHandlers = [
            { request in
                XCTAssertEqual(request.url?.absoluteString, "https://meeting.example.com/api/meeting-transcription/sessions/mts_123/chunks/4")
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertTrue((request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data; boundary="))

                let body = try XCTUnwrap(request.httpBody)
                let bodyString = String(decoding: body, as: UTF8.self)
                XCTAssertTrue(bodyString.contains("name=\"audio_file\"; filename=\"chunk.wav\""))
                XCTAssertTrue(bodyString.contains("name=\"start_ms\""))
                XCTAssertTrue(bodyString.contains("name=\"end_ms\""))
                XCTAssertTrue(bodyString.contains("name=\"sha256\""))
                XCTAssertTrue(bodyString.contains("name=\"mime_type\""))
                XCTAssertTrue(bodyString.contains("name=\"file_size_bytes\""))
                XCTAssertTrue(bodyString.contains("chunk-audio"))
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 201),
                    #"""
                    {"request_id":"req_upload","data":{"session_id":"mts_123","chunk_index":4,"status":"upload_received","upload_status":"uploaded","process_status":"pending"},"error":null}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = MeetingRemoteTranscriptionClient(session: session, configProvider: config)
        let response = try await client.uploadChunk(
            .fixture(
                sessionID: "mts_123",
                chunkIndex: 4,
                audioData: audioData,
                fileName: "chunk.wav"
            )
        )

        XCTAssertEqual(response.sessionID, "mts_123")
        XCTAssertEqual(response.chunkIndex, 4)
        XCTAssertEqual(response.uploadStatus, "uploaded")
        XCTAssertEqual(response.processStatus, "pending")
    }

    func testFinalizeAndGetSessionDecodeEnvelope() async throws {
        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "https://meeting.example.com",
                apiPrefix: "",
                apiKey: "remote_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0,
                topP: 1,
                doSample: false,
                repetitionPenalty: 1
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                XCTAssertEqual(request.url?.absoluteString, "https://meeting.example.com/api/meeting-transcription/sessions/mts_123/finalize")
                XCTAssertEqual(request.httpMethod, "POST")
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"request_id":"req_finalize","data":{"session_id":"mts_123","status":"finalized","selected_input_mode":"live_chunks","missing_chunk_indexes":[2,3]},"error":null}
                    """#.data(using: .utf8)!
                )
            },
            { request in
                XCTAssertEqual(request.url?.absoluteString, "https://meeting.example.com/api/meeting-transcription/sessions/mts_123")
                XCTAssertEqual(request.httpMethod, "GET")
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"request_id":"req_status","data":{"session_id":"mts_123","status":"processing","input_mode":"live_chunks","chunk_duration_ms":300000,"chunk_overlap_ms":2500,"expected_chunk_count":5,"uploaded_chunk_count":4},"error":null}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = MeetingRemoteTranscriptionClient(session: session, configProvider: config)
        let finalized = try await client.finalizeSession(
            sessionID: "mts_123",
            request: .fixture(expectedChunkCount: 5)
        )
        let status = try await client.getSessionStatus(sessionID: "mts_123")

        XCTAssertEqual(finalized.sessionID, "mts_123")
        XCTAssertEqual(finalized.status, "finalized")
        XCTAssertEqual(finalized.selectedInputMode, "live_chunks")
        XCTAssertEqual(finalized.missingChunkIndexes, [2, 3])

        XCTAssertEqual(status.sessionID, "mts_123")
        XCTAssertEqual(status.status, "processing")
        XCTAssertEqual(status.inputMode, "live_chunks")
        XCTAssertEqual(status.expectedChunkCount, 5)
        XCTAssertEqual(status.uploadedChunkCount, 4)
    }

    func testUploadFullAudioUsesMultipartFormDataAndDecodesResponse() async throws {
        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "https://meeting.example.com/v1/chat/completions",
                apiPrefix: "",
                apiKey: "remote_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0,
                topP: 1,
                doSample: false,
                repetitionPenalty: 1
            )
        )

        let audioData = Data("full-audio".utf8)
        URLProtocolStub.requestHandlers = [
            { request in
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://meeting.example.com/api/meeting-transcription/sessions/mts_123/full-audio"
                )
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertTrue((request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data; boundary="))

                let body = try XCTUnwrap(request.httpBody)
                let bodyString = String(decoding: body, as: UTF8.self)
                XCTAssertTrue(bodyString.contains("name=\"audio_file\"; filename=\"meeting.wav\""))
                XCTAssertTrue(bodyString.contains("name=\"sha256\""))
                XCTAssertTrue(bodyString.contains("name=\"duration_ms\""))
                XCTAssertTrue(bodyString.contains("name=\"mime_type\""))
                XCTAssertTrue(bodyString.contains("name=\"file_size_bytes\""))
                XCTAssertTrue(bodyString.contains("full-audio"))
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 201),
                    #"""
                    {"request_id":"req_full_audio","data":{"session_id":"mts_123","status":"full_audio_uploaded","input_mode":"full_audio_fallback"},"error":null}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = MeetingRemoteTranscriptionClient(session: session, configProvider: config)
        let response = try await client.uploadFullAudio(
            .fixture(
                sessionID: "mts_123",
                audioData: audioData,
                fileName: "meeting.wav"
            )
        )

        XCTAssertEqual(response.sessionID, "mts_123")
        XCTAssertEqual(response.status, "full_audio_uploaded")
        XCTAssertEqual(response.inputMode, "full_audio_fallback")
    }

    func testGetSessionStatusDecodesCompletedTranscriptPayload() async throws {
        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "https://meeting.example.com",
                apiPrefix: "",
                apiKey: "remote_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0,
                topP: 1,
                doSample: false,
                repetitionPenalty: 1
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                XCTAssertEqual(request.url?.absoluteString, "https://meeting.example.com/api/meeting-transcription/sessions/mts_done")
                return (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 200),
                    #"""
                    {"request_id":"req_done","data":{"session_id":"mts_done","status":"completed","input_mode":"live_chunks","full_text":"hello world","segments":[{"sequence":0,"speaker_label":"Speaker 1","start_ms":0,"end_ms":1000,"text":"hello"},{"sequence":1,"speaker_label":"Speaker 2","start_ms":1000,"end_ms":2000,"text":"world"}]},"error":null}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = MeetingRemoteTranscriptionClient(session: session, configProvider: config)
        let status = try await client.getSessionStatus(sessionID: "mts_done")

        XCTAssertEqual(status.status, "completed")
        XCTAssertEqual(status.transcriptResult?.fullText, "hello world")
        XCTAssertEqual(status.transcriptResult?.segments.count, 2)
        XCTAssertEqual(status.transcriptResult?.segments[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(status.transcriptResult?.segments[0].startMS, 0)
        XCTAssertEqual(status.transcriptResult?.segments[1].text, "world")
    }

    func testCreateSessionSurfacesStructuredAPIError() async throws {
        let session = makeStubSession()
        let config = StubMeetingVibeVoiceConfigProvider(
            config: MeetingVibeVoiceConfig(
                baseURL: "https://meeting.example.com",
                apiPrefix: "",
                apiKey: "remote_key",
                contextInfo: "",
                maxNewTokens: 4096,
                temperature: 0,
                topP: 1,
                doSample: false,
                repetitionPenalty: 1
            )
        )

        URLProtocolStub.requestHandlers = [
            { request in
                (
                    URLProtocolStub.makeHTTPURLResponse(for: request, statusCode: 404),
                    #"""
                    {"request_id":"req_missing","data":null,"error":{"code":"session_not_found","message":"session mts_missing does not exist"}}
                    """#.data(using: .utf8)!
                )
            },
        ]

        let client = MeetingRemoteTranscriptionClient(session: session, configProvider: config)

        do {
            _ = try await client.createSession(.fixture())
            XCTFail("Expected API error")
        } catch let error as MeetingRemoteTranscriptionClientError {
            guard case .apiError(let statusCode, let requestID, let code, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(requestID, "req_missing")
            XCTAssertEqual(code, "session_not_found")
            XCTAssertEqual(message, "session mts_missing does not exist")
            XCTAssertEqual(
                error.localizedDescription,
                "Meeting transcription request failed (404, session_not_found): session mts_missing does not exist"
            )
        }
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private struct StubMeetingVibeVoiceConfigProvider: MeetingVibeVoiceConfigProviding {
    let config: MeetingVibeVoiceConfig

    var meetingVibeVoiceConfig: MeetingVibeVoiceConfig { config }
}

private final class URLProtocolStub: URLProtocol {
    static var requestHandlers: [(URLRequest) throws -> (HTTPURLResponse, Data)] = []
    static var recordedRequests: [URLRequest] = []

    static func makeHTTPURLResponse(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://localhost")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

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

private extension CreateMeetingTranscriptionSessionRequest {
    static func fixture() -> Self {
        .init(
            clientSessionToken: "client_123",
            source: "macos_meeting",
            chunkDurationMS: 300_000,
            chunkOverlapMS: 2_500,
            audioFormat: "wav",
            sampleRateHZ: 16_000,
            channelCount: 1
        )
    }
}

private extension MeetingRemoteTranscriptionChunkUploadRequest {
    static func fixture(
        sessionID: String,
        chunkIndex: Int,
        audioData: Data,
        fileName: String
    ) -> Self {
        .init(
            sessionID: sessionID,
            chunkIndex: chunkIndex,
            audioData: audioData,
            fileName: fileName,
            startMS: 0,
            endMS: 300_000,
            sha256: "abc123",
            mimeType: "audio/wav",
            fileSizeBytes: audioData.count
        )
    }
}

private extension FinalizeMeetingTranscriptionSessionRequest {
    static func fixture(expectedChunkCount: Int?) -> Self {
        .init(
            expectedChunkCount: expectedChunkCount,
            preferredInputMode: "live_chunks",
            allowFullAudioFallback: true,
            recordingEndedAtMS: 123_456
        )
    }
}

private extension MeetingRemoteTranscriptionFullAudioUploadRequest {
    static func fixture(
        sessionID: String,
        audioData: Data,
        fileName: String
    ) -> Self {
        .init(
            sessionID: sessionID,
            audioData: audioData,
            fileName: fileName,
            sha256: "fullsha256",
            durationMS: 620_000,
            mimeType: "audio/wav",
            fileSizeBytes: audioData.count
        )
    }
}
