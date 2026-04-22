import XCTest
@testable import NeuType

final class MeetingSummaryConfigTests: XCTestCase {
    func testMeetingSummaryConfigAlwaysUsesCanonicalAiWorkerBaseURL() {
        let config = MeetingSummaryConfig(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "ntm_test"
        )

        XCTAssertEqual(config.normalizedBaseURL, MeetingSummaryConfig.defaultBaseURL)
        XCTAssertEqual(
            config.endpointURL(path: "/api/integrations/neutype/meetings")?.absoluteString,
            "https://ai-worker.neuxnet.com/api/integrations/neutype/meetings"
        )
    }

    func testAppPreferencesSanitizesResidualMeetingSummaryBaseURL() {
        let preferences = AppPreferences.shared
        let originalBaseURL = preferences.meetingSummaryBaseURL
        defer {
            preferences.meetingSummaryBaseURL = originalBaseURL
        }

        preferences.meetingSummaryBaseURL = "http://127.0.0.1:8000"
        preferences.sanitizeMeetingSummaryBaseURL()

        XCTAssertEqual(preferences.meetingSummaryBaseURL, MeetingSummaryConfig.defaultBaseURL)
    }
}
