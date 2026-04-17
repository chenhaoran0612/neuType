import XCTest
@testable import NeuType

final class AppDelegateMenuTests: XCTestCase {
    @MainActor
    func testStatusBarMenuPlacesVoiceInputAndMeetingMinutesAtTop() {
        let appDelegate = AppDelegate()

        let menu = appDelegate.makeStatusBarMenu()

        XCTAssertEqual(menu.items[safe: 0]?.title, "打开语音输入")
        XCTAssertEqual(menu.items[safe: 1]?.title, "打开会议记录")
        XCTAssertEqual(menu.items[safe: 2]?.isSeparatorItem, true)
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
