import XCTest
@testable import NeuType

final class RealTimeMeetingCaptionLanguageTests: XCTestCase {
    func testSupportedLanguagesAreLimitedToChineseEnglishAndArabic() {
        XCTAssertEqual(
            RealTimeMeetingCaptionLanguage.allCases,
            [.chineseSimplified, .english, .arabic]
        )
    }

    func testAzureLanguageCodesMatchDocumentedCodes() {
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.chineseSimplified.azureTargetLanguageCode, "zh-Hans")
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.english.azureTargetLanguageCode, "en")
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.arabic.azureTargetLanguageCode, "ar")
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.chineseSimplified.azureSourceLanguageCode, "zh-CN")
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.english.azureSourceLanguageCode, "en-US")
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.arabic.azureSourceLanguageCode, "ar-SA")
    }

    func testYoudaoLanguageCodesRemainAvailableForLegacyCompatibility() {
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.chineseSimplified.youdaoLanguageCode, "zh-CHS")
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.english.youdaoLanguageCode, "en")
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.arabic.youdaoLanguageCode, "ar")
    }

    func testAzureAutoDetectSourceLanguageCandidatesIncludeArabicDialects() {
        XCTAssertEqual(
            RealTimeMeetingCaptionLanguage.azureAutoDetectSourceLanguageCodes,
            ["zh-CN", "en-US", "ar-SA", "ar-EG", "ar-AE"]
        )
    }

    func testStoredLanguageFallsBackToEnglish() {
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.language(from: "missing"), .english)
        XCTAssertEqual(RealTimeMeetingCaptionLanguage.language(from: "arabic"), .arabic)
    }
}
