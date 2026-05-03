import XCTest
@testable import NeuType

final class AzureLiveCaptionProviderTests: XCTestCase {
    func testAutoDetectSourceLanguageCandidatesAreLimitedToSupportedInputLanguages() {
        XCTAssertEqual(
            AzureLiveCaptionProviderConfiguration.autoDetectSourceLanguageCodes,
            ["zh-CN", "en-US", "ar-SA", "ar-EG", "ar-AE"]
        )
    }

    func testCredentialsUseAzureKeyAndRegion() {
        let credentials = LiveMeetingCaptionCredentials(subscriptionKey: " key ", region: " eastus ")

        XCTAssertTrue(credentials.isConfigured)
        XCTAssertEqual(credentials.trimmedSubscriptionKey, "key")
        XCTAssertEqual(credentials.trimmedRegion, "eastus")
    }
}
