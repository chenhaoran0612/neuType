import SwiftUI

struct MeetingDetailView: View {
    @StateObject private var viewModel: MeetingDetailViewModel
    @State private var draftTitle = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFieldFocused: Bool
    private let layout: MeetingWorkspaceLayout

    init(meeting: MeetingRecord, layout: MeetingWorkspaceLayout) {
        self.layout = layout
        _viewModel = StateObject(
            wrappedValue: MeetingDetailViewModel(
                meetingID: meeting.id,
                audioURL: meeting.audioURL
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .padding(.top, 20)

            Group {
                switch viewModel.activeTab {
                case .audio:
                    MeetingAudioPane(viewModel: viewModel, layout: layout)
                case .transcript:
                    MeetingTranscriptPane(viewModel: viewModel, layout: layout)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, layout.detailHorizontalPadding)
        .padding(.vertical, layout.detailVerticalPadding)
        .navigationTitle(viewModel.meeting?.title ?? "Meeting")
        .task {
            try? await viewModel.load()
            draftTitle = displayTitle(viewModel.meeting?.title) ?? ""
        }
        .onChange(of: viewModel.meeting?.title) { _, newValue in
            guard !isEditingTitle else { return }
            draftTitle = displayTitle(newValue) ?? ""
        }
        .onChange(of: isTitleFieldFocused) { _, isFocused in
            if !isFocused && isEditingTitle {
                saveTitle()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if isEditingTitle {
                        TextField("会议标题", text: $draftTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: layout.detailTitleFontSize, weight: .bold))
                            .focused($isTitleFieldFocused)
                            .onSubmit {
                                saveTitle()
                            }
                    } else {
                        Text(displayTitle(viewModel.meeting?.title) ?? "会议")
                            .font(.system(size: layout.detailTitleFontSize, weight: .bold))
                            .lineLimit(1)
                    }

                    Button {
                        draftTitle = displayTitle(viewModel.meeting?.title) ?? ""
                        isEditingTitle = true
                        isTitleFieldFocused = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if let meeting = viewModel.meeting {
                    Text("\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))  ·  \(formatDuration(meeting.duration))")
                        .font(.system(size: layout.detailMetadataFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                ForEach(MeetingDetailTab.allCases, id: \.self) { tab in
                    Button {
                        viewModel.activeTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: layout.tabFontSize, weight: .semibold))
                            .foregroundStyle(viewModel.activeTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(
                                VStack(spacing: 0) {
                                    Spacer()
                                    Rectangle()
                                        .fill(viewModel.activeTab == tab ? Color.accentColor : Color.clear)
                                        .frame(height: 3)
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .background(
                        Rectangle()
                            .fill(viewModel.activeTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                    )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .fixedSize()
        }
        .frame(maxWidth: layout.detailContentMaxWidth, alignment: .leading)
    }

    private func displayTitle(_ title: String?) -> String? {
        guard let title else { return nil }
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

    private func saveTitle() {
        let proposedTitle = draftTitle
        isEditingTitle = false
        isTitleFieldFocused = false

        Task {
            try? await viewModel.renameMeeting(to: proposedTitle)
            draftTitle = displayTitle(viewModel.meeting?.title) ?? draftTitle
        }
    }
}

private struct MeetingAudioPane: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    @ObservedObject private var playbackCoordinator: MeetingPlaybackCoordinator
    @State private var isEditingSlider = false
    private let layout: MeetingWorkspaceLayout

    init(viewModel: MeetingDetailViewModel, layout: MeetingWorkspaceLayout) {
        self.viewModel = viewModel
        self.layout = layout
        _playbackCoordinator = ObservedObject(wrappedValue: viewModel.playbackCoordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("会议录音")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                Text("点击播放并拖动进度条回听本次会议。")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                if let meeting = viewModel.meeting {
                    Text(meeting.audioFileName)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: {
                            playbackCoordinator.currentTime
                        },
                        set: { newValue in
                            viewModel.seekPlayback(to: newValue)
                        }
                    ),
                    in: 0...max(playbackCoordinator.duration, 0.1),
                    onEditingChanged: { isEditing in
                        isEditingSlider = isEditing
                    }
                )
                .frame(maxWidth: .infinity)
                .tint(Color.accentColor)

                Button {
                    playbackCoordinator.seek(to: 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(PlayerIconButtonStyle())

                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: playbackCoordinator.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PlayerIconButtonStyle(prominent: true))

                Button {
                    viewModel.seekPlayback(to: min(playbackCoordinator.currentTime + 10, playbackCoordinator.duration))
                } label: {
                    Image(systemName: "goforward.10")
                }
                .buttonStyle(PlayerIconButtonStyle())

                Text(formatDuration(playbackCoordinator.currentTime))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("/")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.6))

                Text(formatDuration(playbackCoordinator.duration))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .frame(maxWidth: layout.playerBarMaxWidth, alignment: .leading)
        }
        .padding(.top, 16)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct MeetingTranscriptPane: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    private let layout: MeetingWorkspaceLayout

    init(viewModel: MeetingDetailViewModel, layout: MeetingWorkspaceLayout) {
        self.viewModel = viewModel
        self.layout = layout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索文字记录", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 8, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(viewModel.filteredSegments) { segment in
                        Button {
                            viewModel.playSegment(segment)
                        } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.14))
                                    .frame(width: 26, height: 26)
                                    .overlay(
                                        Text(speakerBadge(for: segment.speakerLabel))
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                    )

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 10) {
                                        Text(segment.speakerLabel)
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        Text(formatTimestamp(segment.startTime))
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(segment.text)
                                        .font(.system(size: 9, weight: .regular))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: layout.detailContentMaxWidth, alignment: .leading)
    }

    private func speakerBadge(for label: String) -> String {
        if let last = label.split(separator: " ").last, last.count == 1 {
            return String(last)
        }
        return String(label.prefix(1)).uppercased()
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct PlayerIconButtonStyle: ButtonStyle {
    let prominent: Bool

    init(prominent: Bool = false) {
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 9 : 8, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: prominent ? 26 : 20, height: prominent ? 26 : 20)
            .background(
                Circle()
                    .fill(prominent ? Color.accentColor : Color.black.opacity(0.06))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
