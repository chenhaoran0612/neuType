import SwiftUI
import KeyboardShortcuts

struct MeetingRootView: View {
    @EnvironmentObject private var meetingSession: MeetingSessionController
    @StateObject private var listViewModel = MeetingListViewModel()
    @State private var selectedMeetingID: UUID?

    private var meetingShortcutDescription: String {
        if let shortcut = KeyboardShortcuts.Shortcut(name: .toggleMeetingRecord) {
            return shortcut.description
        }

        return "the configured meeting shortcut"
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = MeetingWorkspaceLayout(
                containerWidth: geometry.size.width,
                containerHeight: geometry.size.height
            )

            ZStack(alignment: .topTrailing) {
                HSplitView {
                    sidebar(layout: layout)
                        .frame(
                            minWidth: layout.sidebarWidth,
                            idealWidth: layout.sidebarWidth,
                            maxWidth: layout.sidebarWidth
                        )

                    detailArea(layout: layout)
                        .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

                Button {
                    meetingSession.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 22)
                .padding(.trailing, 22)
            }
        }
        .task {
            await listViewModel.load()
            syncSelection()
        }
        .onChange(of: meetingSession.lastCompletedMeetingID) { _, _ in
            syncSelection()
        }
        .onChange(of: listViewModel.meetings) { _, _ in
            syncSelection()
        }
    }

    private func sidebar(layout: MeetingWorkspaceLayout) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("会议记录")
                    .font(.system(size: layout.sidebarTitleFontSize, weight: .bold))
                Text("独立查看会议录音、文字记录，以及后续的结构化结果。")
                    .font(.system(size: layout.sidebarBodyFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("全部会议")
                    .font(.system(size: layout.sidebarSectionTitleFontSize, weight: .semibold))
                MeetingListView(
                    viewModel: listViewModel,
                    selection: $selectedMeetingID,
                    onDelete: handleDelete
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, layout.sidebarHorizontalPadding)
        .padding(.vertical, 36)
        .background(
            LinearGradient(
                colors: [Color.white, Color(red: 0.985, green: 0.987, blue: 0.994)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(width: 1)
        }
    }

    private func detailArea(layout: MeetingWorkspaceLayout) -> some View {
        Group {
            if let meeting = listViewModel.meeting(id: selectedMeetingID) {
                MeetingDetailView(meeting: meeting, layout: layout)
                    .id(meeting.id)
            } else {
                ContentUnavailableView(
                    "Meeting History",
                    systemImage: "person.2.wave.2",
                    description: Text("Use `\(meetingShortcutDescription)` to start meeting recording directly in the floating overlay.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private func syncSelection() {
        if let lastCompletedMeetingID = meetingSession.lastCompletedMeetingID,
           listViewModel.meeting(id: lastCompletedMeetingID) != nil {
            selectedMeetingID = lastCompletedMeetingID
            return
        }

        if let selectedMeetingID, listViewModel.meeting(id: selectedMeetingID) == nil {
            self.selectedMeetingID = listViewModel.meetings.first?.id
            return
        }

        if selectedMeetingID == nil {
            selectedMeetingID = listViewModel.meetings.first?.id
        }
    }

    private func handleDelete(_ meeting: MeetingRecord) {
        let deletedID = meeting.id
        if selectedMeetingID == deletedID {
            selectedMeetingID = listViewModel.meetings.first(where: { $0.id != deletedID })?.id
        }

        Task {
            await listViewModel.deleteMeeting(id: deletedID)
            await MainActor.run {
                syncSelection()
            }
        }
    }

    private func displayTitle(for title: String) -> String {
        if title.hasPrefix("Meeting ") {
            return String(title.dropFirst("Meeting ".count))
        }
        return title
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
