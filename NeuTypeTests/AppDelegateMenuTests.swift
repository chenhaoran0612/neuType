import XCTest
@testable import NeuType

final class AppDelegateMenuTests: XCTestCase {
    @MainActor
    func testStatusBarMenuPlacesVoiceInputMeetingMinutesAndCaptionsAtTop() {
        let appDelegate = AppDelegate()

        let menu = appDelegate.makeStatusBarMenu()

        XCTAssertEqual(menu.items[safe: 0]?.title, "打开语音输入")
        XCTAssertEqual(menu.items[safe: 1]?.title, "打开会议记录")
        XCTAssertEqual(menu.items[safe: 2]?.title, "打开实时会议字幕")
        XCTAssertEqual(menu.items[safe: 3]?.isSeparatorItem, true)
        XCTAssertEqual(menu.items.first(where: { $0.title == "Language" }), nil)
        XCTAssertEqual(menu.items.first(where: { $0.title == "Microphone" })?.title, "Microphone")
        XCTAssertEqual(menu.items.first(where: { $0.title == "设置" })?.title, "设置")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
