import Foundation

extension Notification.Name {
    static let appPreferencesLanguageChanged = Notification.Name("AppPreferencesLanguageChanged")
    static let hotkeySettingsChanged = Notification.Name("HotkeySettingsChanged")
    static let indicatorWindowDidHide = Notification.Name("IndicatorWindowDidHide")
    static let meetingRecordsDidChange = Notification.Name("MeetingRecordsDidChange")
    static let returnToHome = Notification.Name("ReturnToHome")
    static let openVoiceInput = Notification.Name("OpenVoiceInput")
    static let openSettings = Notification.Name("OpenSettings")
    static let openMeetingMinutes = Notification.Name("OpenMeetingMinutes")
    static let toggleMeetingMinutesShortcut = Notification.Name("ToggleMeetingMinutesShortcut")
    static let toggleMeetingPlayback = Notification.Name("ToggleMeetingPlayback")
}
