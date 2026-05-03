import XCTest
@testable import NeuType

final class YoudaoLiveCaptionProviderTests: XCTestCase {
    func testV4SignatureUsesAppKeySaltCurtimeAndSecret() {
        let signature = YoudaoLiveCaptionSigner.sign(
            appKey: "appKey",
            salt: "salt",
            currentTime: "1757560399",
            appSecret: "secret"
        )

        XCTAssertEqual(
            signature,
            "36ce055e8fedbf4fb9f6fe3fce2768a3ea285d34ccf3ec16cacf9f3f7bf45e84"
        )
    }

    func testAuthenticationURLContainsRequiredQueryParameters() throws {
        let url = try YoudaoLiveCaptionURLBuilder().makeURL(
            credentials: LiveMeetingCaptionCredentials(appKey: "key", appSecret: "secret"),
            targetLanguage: .chineseSimplified,
            salt: "salt",
            currentTime: "1757560399"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "openapi.youdao.com")
        XCTAssertEqual(url.path, "/stream-audio/stream-si")
        XCTAssertEqual(query["appKey"], "key")
        XCTAssertEqual(query["salt"], "salt")
        XCTAssertEqual(query["curtime"], "1757560399")
        XCTAssertEqual(query["from"], "auto")
        XCTAssertEqual(query["to"], "zh-CHS")
        XCTAssertEqual(query["speakerRequired"], "false")
        XCTAssertEqual(query["ttsRequired"], "false")
        XCTAssertEqual(
            query["sign"],
            "9e10866956f628dad6f7bbc07841a1ed239792231a7880378ddaa0ae78f0798a"
        )
    }

    func testParserMapsPartialRecognitionToTemporarySegment() throws {
        let event = try XCTUnwrap(YoudaoLiveCaptionResponseParser.parse(Self.partialRecognitionJSON))

        guard case .segment(let segment) = event else {
            return XCTFail("Expected segment event")
        }

        XCTAssertEqual(segment.id, 1)
        XCTAssertEqual(segment.sourceText, "This is English testing.")
        XCTAssertEqual(segment.translatedText, "这是英语测试。")
        XCTAssertFalse(segment.isFinal)
        XCTAssertEqual(segment.startMilliseconds, 0)
        XCTAssertEqual(segment.endMilliseconds, 1860)
    }

    func testParserMapsCompleteRecognitionToFinalSegment() throws {
        let event = try XCTUnwrap(YoudaoLiveCaptionResponseParser.parse(Self.finalRecognitionJSON))

        guard case .segment(let segment) = event else {
            return XCTFail("Expected segment event")
        }

        XCTAssertEqual(segment.id, 2)
        XCTAssertTrue(segment.isFinal)
        XCTAssertEqual(segment.sourceText, "Hello")
        XCTAssertEqual(segment.translatedText, "你好")
    }

    func testParserMapsAuthenticationFailureToReadableError() throws {
        let event = try XCTUnwrap(YoudaoLiveCaptionResponseParser.parse(#"{"result":[],"msg":"signature check failed","errorCode":"202"}"#))

        XCTAssertEqual(event, .error(message: "有道签名校验失败，请检查 App Key 和 App Secret。"))
    }

    func testParserMapsPermissionDeniedToServiceAccessError() throws {
        let event = try XCTUnwrap(YoudaoLiveCaptionResponseParser.parse(#"{"result":[],"msg":"service access denied","errorCode":"110"}"#))

        XCTAssertEqual(
            event,
            .error(message: "有道返回 110：当前应用 ID 没有权限访问此服务。请在有道控制台给这个应用开通“大模型同声传译”，并确认 App Key 和 App Secret 属于同一个应用。")
        )
    }

    private static let partialRecognitionJSON = #"""
    {
      "errorCode": "0",
      "action": "recognition",
      "result": [
        {
          "st": {
            "sentence": "This is English testing.",
            "bg": 0,
            "ed": 1860,
            "type": 1,
            "partial": true,
            "translation": "这是英语测试。",
            "speaker": "0"
          },
          "segId": 1
        }
      ],
      "isEnd": false
    }
    """#

    private static let finalRecognitionJSON = #"""
    {
      "errorCode": "0",
      "action": "recognition",
      "result": [
        {
          "st": {
            "sentence": "Hello",
            "bg": 1860,
            "ed": 2400,
            "type": 0,
            "partial": false,
            "translation": "你好",
            "speaker": "0"
          },
          "segId": 2
        }
      ],
      "isEnd": false
    }
    """#
}
