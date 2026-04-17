import Foundation

enum MeetingExportFormatter {
    static func transcriptText(
        meetingTitle: String,
        meetingDate: Date,
        segments: [MeetingTranscriptSegment]
    ) -> String {
        let header = """
        \(displayTitle(meetingTitle))
        会议时间：\(formatMeetingDate(meetingDate))
        """

        let body = segments
            .map { segment in
                """
                \(localizedSpeakerLabel(segment.speakerLabel))  \(formatTimestamp(segment.startTime))
                \(segment.text)
                """
            }
            .joined(separator: "\n\n")

        if body.isEmpty {
            return header
        }

        return "\(header)\n\n\(body)"
    }

    static func audioFileName(meetingTitle: String, originalFileName: String) -> String {
        let displayedTitle = displayTitle(meetingTitle)
        let sanitizedTitle = sanitizeFileName(displayedTitle)
        let fallbackBaseName = URL(fileURLWithPath: originalFileName).deletingPathExtension().lastPathComponent
        let baseName = sanitizedTitle.isEmpty ? fallbackBaseName : sanitizedTitle
        let ext = URL(fileURLWithPath: originalFileName).pathExtension
        guard !ext.isEmpty else { return baseName }
        return "\(baseName).\(ext)"
    }

    static func localizedSpeakerLabel(_ label: String) -> String {
        if label.hasPrefix("Speaker "),
           let suffix = label.split(separator: " ").last {
            return "说话人\(suffix)"
        }

        if label == "Unknown" {
            return "未知说话人"
        }

        return label
    }

    static func formatTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func formatMeetingDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func displayTitle(_ title: String) -> String {
        guard title.hasPrefix("Meeting ") else { return title }
        return String(title.dropFirst("Meeting ".count))
    }

    private static func sanitizeFileName(_ title: String) -> String {
        let illegalCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = title.components(separatedBy: illegalCharacters)
        return components
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
