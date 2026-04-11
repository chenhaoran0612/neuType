import SwiftUI

struct MeetingListView: View {
    @ObservedObject var viewModel: MeetingListViewModel

    var body: some View {
        List(viewModel.meetings) { meeting in
            NavigationLink(value: meeting.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.headline)
                    Text(meeting.createdAt, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !meeting.transcriptPreview.isEmpty {
                        Text(meeting.transcriptPreview)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .overlay {
            if viewModel.meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2")
            }
        }
        .task {
            await viewModel.load()
        }
    }
}
