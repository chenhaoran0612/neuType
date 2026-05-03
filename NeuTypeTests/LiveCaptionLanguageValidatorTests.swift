import XCTest
@testable import NeuType

final class LiveCaptionLanguageValidatorTests: XCTestCase {
    func testChineseTargetRejectsArabicText() {
        XCTAssertFalse(LiveCaptionLanguageValidator.isDisplayable("مرحبا بكم", as: .chineseSimplified))
        XCTAssertTrue(LiveCaptionLanguageValidator.isDisplayable("欢迎参加今天的会议。", as: .chineseSimplified))
    }

    func testArabicTargetRejectsChineseText() {
        XCTAssertFalse(LiveCaptionLanguageValidator.isDisplayable("欢迎参加今天的会议。", as: .arabic))
        XCTAssertTrue(LiveCaptionLanguageValidator.isDisplayable("مرحبا بكم في الاجتماع", as: .arabic))
    }

    func testArabicTargetRejectsMixedScriptText() {
        XCTAssertFalse(LiveCaptionLanguageValidator.isDisplayable("مرحبا meeting 你好", as: .arabic))
    }

    func testEnglishTargetRejectsArabicText() {
        XCTAssertFalse(LiveCaptionLanguageValidator.isDisplayable("مرحبا بكم", as: .english))
        XCTAssertTrue(LiveCaptionLanguageValidator.isDisplayable("Welcome to the meeting.", as: .english))
    }

    func testEmptyTranslationIsNotDisplayable() {
        XCTAssertFalse(LiveCaptionLanguageValidator.isDisplayable("", as: .english))
        XCTAssertFalse(LiveCaptionLanguageValidator.isDisplayable("   ", as: .arabic))
    }
}
