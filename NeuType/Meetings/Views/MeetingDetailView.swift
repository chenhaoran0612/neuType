import AppKit
import SwiftUI
import WebKit

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
                case .summary:
                    MeetingSummaryPane(viewModel: viewModel, layout: layout)
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
        .background(WindowDragConfigurator())
        .task {
            try? await viewModel.load()
            draftTitle = displayTitle(viewModel.meeting?.title) ?? ""
        }
        .onChange(of: viewModel.meeting?.title) { _, newValue in
            guard !isEditingTitle else { return }
            draftTitle = displayTitle(newValue) ?? ""
        }
        .onChange(of: viewModel.activeTab) { _, activeTab in
            MeetingLog.info("Meeting detail tab switched to \(activeTab.rawValue)")
        }
        .onChange(of: isTitleFieldFocused) { _, isFocused in
            if !isFocused && isEditingTitle {
                saveTitle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMeetingPlayback)) { _ in
            viewModel.togglePlayback()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
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

                    if viewModel.activeTab == .summary,
                       (viewModel.shareURL != nil || viewModel.shouldShowSummaryLogButton) {
                        MeetingSummaryHeaderActions(
                            shareURL: viewModel.shareURL,
                            logText: viewModel.summaryLogDisplayText,
                            showsLogButton: viewModel.shouldShowSummaryLogButton
                        )
                            .padding(.leading, 6)
                    }
                }
                if let meeting = viewModel.meeting {
                    Text("\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))  ·  \(formatDuration(meeting.duration))")
                        .font(.system(size: layout.detailMetadataFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 24)

            tabSwitcher
        }
        .frame(maxWidth: layout.detailContentMaxWidth, alignment: .leading)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(MeetingDetailTab.displayOrder, id: \.self) { tab in
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

private struct MeetingSummaryPane: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    private let layout: MeetingWorkspaceLayout

    init(viewModel: MeetingDetailViewModel, layout: MeetingWorkspaceLayout) {
        self.viewModel = viewModel
        self.layout = layout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch viewModel.summaryState {
            case .blocked(let message):
                summaryStatusPanel(
                    title: "等待文字记录完成",
                    message: message,
                    showsProgress: false,
                    buttonTitle: nil,
                    action: nil
                )
            case .unconfigured:
                summaryStatusPanel(
                    title: "请先配置服务端",
                    message: "在设置中填写 ai-worker 服务地址和 API Key 后，才能提交会议总结任务。",
                    showsProgress: false,
                    buttonTitle: nil,
                    action: nil
                )
            case .unsubmitted:
                summaryStatusPanel(
                    title: "尚未提交到服务端",
                    message: "这场会议的文字记录已经准备好。点击开始处理后，会把音频和 transcript 提交到 ai-worker 生成总结结果。",
                    showsProgress: false,
                    buttonTitle: "开始处理"
                ) {
                    Task { await viewModel.processSummary() }
                }
            case .processing(let status):
                summaryStatusPanel(
                    title: "正在生成总结",
                    message: statusMessage(for: status),
                    showsProgress: true,
                    buttonTitle: nil,
                    action: nil
                )
            case .failed(let message):
                summaryStatusPanel(
                    title: "总结生成失败",
                    message: message.isEmpty ? "服务端处理失败，请重新尝试。" : message,
                    showsProgress: false,
                    buttonTitle: "重新处理"
                ) {
                    Task { await viewModel.processSummary() }
                }
            case .completed:
                completedSummaryView
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .frame(maxWidth: layout.detailContentMaxWidth, alignment: .leading)
    }

    private var completedSummaryView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if !viewModel.summaryFullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    summaryCard {
                        MarkdownTextView(markdown: viewModel.summaryFullText)
                    }
                } else {
                    summaryStatusPanel(
                        title: "还没有可展示的总结",
                        message: "当前会议的 full_text 为空，请重新生成总结。",
                        showsProgress: false,
                        buttonTitle: "重新处理"
                    ) {
                        Task { await viewModel.processSummary() }
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func summarySection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func summaryCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 13, weight: .bold))
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func summaryStatusPanel(
        title: String,
        message: String,
        showsProgress: Bool,
        buttonTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            let messageLines = splitMeetingStatusMessage(message)
            VStack(alignment: .leading, spacing: 4) {
                Text(messageLines.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = messageLines.detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func statusMessage(for status: MeetingSummaryStatus) -> String {
        switch status {
        case .received:
            return "服务端已收到这场会议，正在初始化总结任务。"
        case .queued:
            return "总结任务已入队，正在等待 personal PM 执行。"
        case .processing:
            return "personal PM 正在分析会议内容并生成总结，请稍候。"
        default:
            return "正在处理，请稍候。"
        }
    }
}

private struct MeetingSummaryHeaderActions: View {
    let shareURL: URL?
    let logText: String
    let showsLogButton: Bool

    @State private var isShowingSummaryLog = false

    var body: some View {
        HStack(spacing: 8) {
            if let shareURL {
                MeetingShareActionButtons(shareURL: shareURL)
            }

            if showsLogButton {
                Button {
                    isShowingSummaryLog = true
                } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $isShowingSummaryLog) {
            MeetingSummaryLogSheet(logText: logText)
        }
    }
}

private struct MeetingShareActionButtons: View {
    let shareURL: URL
    @State private var didCopyShareLink = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(shareURL)
            } label: {
                Label("打开", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
                didCopyShareLink = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopyShareLink = false
                }
            } label: {
                Label(didCopyShareLink ? "已复制" : "分享", systemImage: didCopyShareLink ? "checkmark" : "link")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct MeetingSummaryLogSheet: View {
    let logText: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopyLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("最新接口返回")
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                    didCopyLog = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopyLog = false
                    }
                } label: {
                    Label(didCopyLog ? "已复制" : "复制", systemImage: didCopyLog ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView {
                Text(logText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
    }
}

private struct MeetingTranscriptPane: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    @ObservedObject private var playbackCoordinator: MeetingPlaybackCoordinator
    @State private var transcriptFailureDetails = ""
    @State private var showingTranscriptFailureDetails = false
    @State private var showingTranscriptLogs = false
    private let layout: MeetingWorkspaceLayout

    init(viewModel: MeetingDetailViewModel, layout: MeetingWorkspaceLayout) {
        self.viewModel = viewModel
        self.layout = layout
        _playbackCoordinator = ObservedObject(wrappedValue: viewModel.playbackCoordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch viewModel.transcriptState {
            case .unprocessed:
                transcriptStatusPanel(
                    title: "这条会议还没有转成文字记录",
                    message: "音频已经保存，你可以随时开始处理并生成说话人分段结果。",
                    buttonTitle: "开始处理",
                    action: {
                        viewModel.startTranscriptProcessing()
                    }
                )
            case .processing:
                transcriptStatusPanel(
                    title: "正在处理音频",
                    message: viewModel.transcriptProcessingMessage,
                    progress: viewModel.transcriptProgress,
                    buttonTitle: nil,
                    showsLogButton: true,
                    logAction: {
                        showingTranscriptLogs = true
                    },
                    action: nil
                )
            case .failed(let message):
                transcriptStatusPanel(
                    title: "文字记录处理失败",
                    message: message.isEmpty ? "处理过程中出现错误，请重新尝试。" : message,
                    buttonTitle: "重新处理",
                    secondaryButtonTitle: message.isEmpty ? nil : "查看失败原因",
                    secondaryAction: message.isEmpty ? nil : {
                        transcriptFailureDetails = message
                        showingTranscriptFailureDetails = true
                    },
                    showsLogButton: true,
                    logAction: {
                        showingTranscriptLogs = true
                    },
                    action: {
                        viewModel.startTranscriptProcessing()
                    }
                )
            case .completed:
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索文字记录", text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )

                    Picker("", selection: $viewModel.selectedTranscriptLanguage) {
                        ForEach(MeetingTranscriptLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 220)

                    Button {
                        exportTranscript()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("下载文字记录")
                    .accessibilityLabel("下载文字记录")
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.filteredTranscriptRows) { row in
                                Button {
                                    viewModel.playSegment(row.segment)
                                } label: {
                                    HStack(alignment: .top, spacing: 14) {
                                        Circle()
                                            .fill(Color.accentColor.opacity(0.14))
                                            .frame(width: 26, height: 26)
                                            .overlay(
                                                Text(speakerBadge(for: row.speakerLabel))
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundStyle(Color.accentColor)
                                            )

                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 10) {
                                                Text(row.speakerLabel)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                                Text(formatTimestamp(row.startTime))
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                            }

                                            Text(row.text)
                                                .font(.system(size: 13, weight: .regular))
                                                .foregroundStyle(.primary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(playbackCoordinator.activeSegmentSequence == row.sequence ? Color.accentColor.opacity(0.18) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(playbackCoordinator.activeSegmentSequence == row.sequence ? Color.accentColor.opacity(0.36) : Color.clear, lineWidth: 1.5)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .id(row.sequence)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .onReceive(playbackCoordinator.$activeSegmentSequence.removeDuplicates()) { activeSequence in
                        scrollActiveSegmentIfNeeded(with: proxy, sequence: activeSequence)
                    }
                    .onAppear {
                        scrollActiveSegmentIfNeeded(with: proxy, sequence: playbackCoordinator.activeSegmentSequence)
                    }
                    .onChange(of: viewModel.activeTab) { _, activeTab in
                        guard activeTab == .transcript else { return }
                        scrollActiveSegmentIfNeeded(with: proxy, sequence: playbackCoordinator.activeSegmentSequence)
                    }
                }
            }

            Spacer(minLength: 0)

            MeetingPlaybackBar(viewModel: viewModel, layout: layout)
        }
        .padding(.top, 16)
        .frame(maxWidth: layout.detailContentMaxWidth, alignment: .leading)
        .alert("失败原因", isPresented: $showingTranscriptFailureDetails) {
            Button("关闭", role: .cancel) {}
        } message: {
            Text(transcriptFailureDetails)
        }
        .sheet(isPresented: $showingTranscriptLogs) {
            MeetingTranscriptLogSheet(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func transcriptStatusPanel(
        title: String,
        message: String,
        progress: Float? = nil,
        buttonTitle: String?,
        secondaryButtonTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        showsLogButton: Bool = false,
        logAction: (() -> Void)? = nil,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if showsLogButton, let logAction {
                    Button(action: logAction) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("查看请求日志")
                }
            }

            let messageLines = splitMeetingStatusMessage(message)
            VStack(alignment: .leading, spacing: 4) {
                Text(messageLines.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = messageLines.detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress), total: 1.0)
                        .controlSize(.small)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            if let buttonTitle, let action {
                HStack(spacing: 10) {
                    Button(buttonTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    if let secondaryButtonTitle, let secondaryAction {
                        Button(secondaryButtonTitle, action: secondaryAction)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            } else if progress == nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func speakerBadge(for label: String) -> String {
        if let last = label.split(separator: " ").last, last.count == 1 {
            return String(last)
        }
        return String(label.prefix(1)).uppercased()
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        MeetingExportFormatter.formatTimestamp(time)
    }

    private func exportTranscript() {
        guard let meeting = viewModel.meeting else { return }
        let transcript = MeetingExportFormatter.transcriptText(
            meetingTitle: meeting.title,
            meetingDate: meeting.createdAt,
            segments: viewModel.segments,
            textProvider: { $0.displayText(for: viewModel.selectedTranscriptLanguage) }
        )
        guard !transcript.isEmpty else { return }

        let suggestedName = MeetingExportFormatter.transcriptFileName(
            meetingTitle: meeting.title,
            language: viewModel.selectedTranscriptLanguage
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let destinationURL = panel.url {
            do {
                try transcript.write(to: destinationURL, atomically: true, encoding: .utf8)
                MeetingLog.info("Exported meeting transcript to \(destinationURL.path)")
            } catch {
                MeetingLog.error("Export meeting transcript failed: \(error.localizedDescription)")
            }
        }
    }

    private func scrollActiveSegmentIfNeeded(
        with proxy: ScrollViewProxy,
        sequence: Int?
    ) {
        guard let sequence else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(sequence, anchor: .top)
            }
        }
    }

}

private struct MeetingTranscriptLogSheet: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    @ObservedObject private var requestLogStore = RequestLogStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("请求日志")
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Button {
                    let payload = viewModel.transcriptRequestLogs
                        .map { "\($0.timestamp.formatted(date: .omitted, time: .standard))  \($0.message)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                    didCopyLog = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopyLog = false
                    }
                } label: {
                    Label(didCopyLog ? "已复制" : "复制", systemImage: didCopyLog ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView(showsIndicators: false) {
                transcriptRequestLogsContent
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .id(requestLogStore.entries.count)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }

    @ViewBuilder
    private var transcriptRequestLogsContent: some View {
        let logs = viewModel.transcriptRequestLogs

        if logs.isEmpty {
            Text("暂无请求日志")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(logs) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(entry.message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func splitMeetingStatusMessage(_ message: String) -> (title: String, detail: String?) {
    let lines = message
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard let firstLine = lines.first else {
        return ("正在调用转写服务生成文字记录和说话人分段，请稍候。", nil)
    }
    let detail = lines.dropFirst().joined(separator: "\n")
    return (firstLine, detail.isEmpty ? nil : detail)
}

private struct MeetingPlaybackBar: View {
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
                MeetingLog.info("Meeting playback toggled by play button or space key")
                viewModel.togglePlayback()
            } label: {
                Image(systemName: playbackCoordinator.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(PlayerIconButtonStyle(prominent: true))

            Button {
                viewModel.seekPlayback(to: min(playbackCoordinator.currentTime + 10, playbackCoordinator.duration))
            } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(PlayerIconButtonStyle())

            Text(formatDuration(playbackCoordinator.currentTime))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("/")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))

            Text(formatDuration(playbackCoordinator.duration))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                exportOriginalAudio()
            } label: {
                Label("下载原始音频", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

    private func exportOriginalAudio() {
        let sourceURL = playbackCoordinator.audioURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            MeetingLog.error("Export original audio failed: source file missing at \(sourceURL.path)")
            return
        }

        let suggestedName: String
        if let audioFileName = viewModel.meeting?.audioFileName,
           !audioFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            suggestedName = audioFileName
        } else {
            suggestedName = sourceURL.lastPathComponent
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            MeetingLog.info("Exported original audio to \(destinationURL.path)")
        } catch {
            MeetingLog.error("Export original audio failed: \(error.localizedDescription)")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
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
            .font(.system(size: prominent ? 11 : 10, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: prominent ? 28 : 22, height: prominent ? 28 : 22)
            .background(
                Circle()
                    .fill(prominent ? Color.accentColor : Color.black.opacity(0.06))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct MarkdownTextView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = NonScrollingWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let heightConstraint = webView.heightAnchor.constraint(equalToConstant: 40)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        context.coordinator.heightConstraint = heightConstraint

        load(markdown: markdown, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        load(markdown: markdown, into: nsView, coordinator: context.coordinator)
    }

    private func load(markdown: String, into webView: WKWebView, coordinator: Coordinator) {
        let html = MarkdownHTMLRenderer.documentHTML(from: markdown)
        guard coordinator.lastHTML != html else { return }
        coordinator.lastHTML = html
        MeetingLog.info("Summary markdown web load length=\(markdown.count)")
        webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/"))
    }

    private final class NonScrollingWKWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var heightConstraint: NSLayoutConstraint?
        var lastHTML: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self,
                      let height = result as? CGFloat else { return }
                self.heightConstraint?.constant = max(60, ceil(height))
            }
            MeetingLog.info("Summary markdown web render finished")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MeetingLog.error("Summary markdown web render failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MeetingLog.error("Summary markdown provisional web render failed: \(error.localizedDescription)")
        }
    }
}

private enum MarkdownHTMLRenderer {
    static func documentHTML(from markdown: String) -> String {
        let body = render(markdown)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root {
              color-scheme: light;
              --fg: #151515;
              --muted: #5f5f5f;
              --line: #e7e7ea;
              --accent: #0a84ff;
              --bg: transparent;
            }
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              color: var(--fg);
              font: 14px/1.72 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
            }
            .markdown {
              padding: 0;
            }
            h1, h2, h3, h4, h5, h6 {
              margin: 0 0 14px 0;
              font-weight: 700;
              color: var(--fg);
              line-height: 1.35;
            }
            h1 { font-size: 30px; margin-top: 4px; margin-bottom: 24px; }
            h2 { font-size: 22px; margin-top: 38px; margin-bottom: 16px; }
            h3 { font-size: 18px; margin-top: 28px; margin-bottom: 12px; }
            p {
              margin: 0 0 18px 0;
              color: var(--fg);
            }
            ul, ol {
              margin: 0 0 18px 22px;
              padding: 0 0 0 12px;
            }
            li {
              margin: 0 0 10px 0;
            }
            strong {
              font-weight: 700;
            }
            a {
              color: var(--accent);
              text-decoration: none;
            }
            table {
              width: 100%;
              border-collapse: collapse;
              margin: 18px 0;
              font-size: 13px;
            }
            th, td {
              border: 1px solid var(--line);
              padding: 8px 10px;
              text-align: left;
              vertical-align: top;
            }
            th {
              background: #f7f8fa;
              font-weight: 700;
            }
            code {
              font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
              background: #f3f4f6;
              border-radius: 6px;
              padding: 1px 5px;
            }
            hr {
              border: none;
              border-top: 1px solid var(--line);
              margin: 24px 0;
            }
          </style>
        </head>
        <body>
          <div class="markdown">\(body)</div>
        </body>
        </html>
        """
    }

    static func render(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var html: [String] = []
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                index += 1
                continue
            }

            if let heading = parseHeading(line) {
                html.append("<h\(heading.level)>\(renderInline(heading.text))</h\(heading.level)>")
                index += 1
                continue
            }

            if isTableHeader(line: line, next: index + 1 < lines.count ? lines[index + 1] : nil) {
                let headerCells = parseTableRow(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.contains("|"), !candidate.isEmpty else { break }
                    rows.append(parseTableRow(candidate))
                    index += 1
                }
                html.append(renderTable(headers: headerCells, rows: rows))
                continue
            }

            if isUnorderedList(line) {
                var items: [String] = []
                while index < lines.count, isUnorderedList(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let item = lines[index].trimmingCharacters(in: .whitespaces).dropFirst(2)
                    items.append("<li>\(renderInline(String(item)))</li>")
                    index += 1
                }
                html.append("<ul>\(items.joined())</ul>")
                continue
            }

            if isOrderedList(line) {
                var items: [String] = []
                while index < lines.count, isOrderedList(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    let content = candidate.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    items.append("<li>\(renderInline(content))</li>")
                    index += 1
                }
                html.append("<ol>\(items.joined())</ol>")
                continue
            }

            var paragraphLines: [String] = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || parseHeading(candidate) != nil || isUnorderedList(candidate) || isOrderedList(candidate) || isTableHeader(line: candidate, next: index + 1 < lines.count ? lines[index + 1] : nil) {
                    break
                }
                paragraphLines.append(candidate)
                index += 1
            }
            html.append("<p>\(renderInline(paragraphLines.joined(separator: " ")))</p>")
        }

        return html.joined(separator: "\n")
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let prefixCount = line.prefix { $0 == "#" }.count
        guard prefixCount > 0, prefixCount <= 6 else { return nil }
        let remainder = line.dropFirst(prefixCount).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return (prefixCount, remainder)
    }

    private static func isUnorderedList(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func isOrderedList(_ line: String) -> Bool {
        line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }

    private static func isTableHeader(line: String, next: String?) -> Bool {
        guard line.contains("|"), let next else { return false }
        let trimmedNext = next.trimmingCharacters(in: .whitespaces)
        return trimmedNext.range(of: #"^\|?[\-\s\:|]+\|?$"#, options: .regularExpression) != nil
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func renderTable(headers: [String], rows: [[String]]) -> String {
        let headerHTML = headers.map { "<th>\(renderInline($0))</th>" }.joined()
        let rowHTML = rows.map { row in
            "<tr>" + row.map { "<td>\(renderInline($0))</td>" }.joined() + "</tr>"
        }.joined()
        return "<table><thead><tr>\(headerHTML)</tr></thead><tbody>\(rowHTML)</tbody></table>"
    }

    private static func renderInline(_ text: String) -> String {
        var html = escapeHTML(text)

        html = html.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^)]+)\)"#,
            with: #"<a href="$2">$1</a>"#,
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#,
            with: #"<strong>$1</strong>"#,
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: #"<code>$1</code>"#,
            options: .regularExpression
        )
        return html
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private struct WindowDragConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }
        window.isMovable = true
    }
}
