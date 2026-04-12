import SwiftUI

struct MeetingListView: View {
    @ObservedObject var viewModel: MeetingListViewModel
    @Binding var selection: UUID?
    let onDelete: (MeetingRecord) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(viewModel.meetings) { meeting in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            selection = meeting.id
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(displayTitle(for: meeting.title))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isSelected(meeting) ? Color.white : Color.primary)
                                    .lineLimit(1)

                                Text(meeting.createdAt.formatted(date: .long, time: .shortened))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(isSelected(meeting) ? Color.white.opacity(0.85) : Color.secondary)
                                    .lineLimit(1)

                                if !meeting.transcriptPreview.isEmpty {
                                    Text(meeting.transcriptPreview)
                                        .font(.system(size: 8, weight: .regular))
                                        .foregroundStyle(isSelected(meeting) ? Color.white.opacity(0.76) : Color.secondary.opacity(0.92))
                                        .lineLimit(2)
                                        .padding(.top, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            onDelete(meeting)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(isSelected(meeting) ? Color.white.opacity(0.92) : Color.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground(for: meeting))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor(for: meeting), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if viewModel.meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2")
            }
        }
    }

    private func isSelected(_ meeting: MeetingRecord) -> Bool {
        selection == meeting.id
    }

    private func cardBackground(for meeting: MeetingRecord) -> some ShapeStyle {
        if isSelected(meeting) {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(Color.black.opacity(0.028))
    }

    private func borderColor(for meeting: MeetingRecord) -> Color {
        isSelected(meeting) ? Color.accentColor.opacity(0.22) : Color.black.opacity(0.06)
    }

    private func displayTitle(for title: String) -> String {
        if title.hasPrefix("Meeting ") {
            return String(title.dropFirst("Meeting ".count))
        }
        return title
    }
}
