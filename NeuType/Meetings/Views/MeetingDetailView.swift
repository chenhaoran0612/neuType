import SwiftUI

struct MeetingDetailView: View {
    @StateObject private var viewModel: MeetingDetailViewModel

    init(meeting: MeetingRecord) {
        _viewModel = StateObject(
            wrappedValue: MeetingDetailViewModel(
                meetingID: meeting.id,
                audioURL: meeting.audioURL
            )
        )
    }

    var body: some View {
        List(viewModel.segments) { segment in
            Button {
                viewModel.playSegment(segment)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.speakerLabel)
                        .font(.caption.weight(.semibold))
                    Text("\(segment.startTime.formatted())s - \(segment.endTime.formatted())s")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(segment.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(viewModel.meeting?.title ?? "Meeting")
        .task {
            try? await viewModel.load()
        }
    }
}
