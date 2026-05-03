import SwiftUI

@MainActor
struct RealTimeMeetingCaptionView: View {
    @StateObject private var viewModel: RealTimeMeetingCaptionViewModel
    @StateObject private var microphoneService = MicrophoneService.shared
    @State private var isFailureDetailExpanded = false
    @State private var isLogDrawerExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    init(viewModel: RealTimeMeetingCaptionViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? RealTimeMeetingCaptionViewModel.shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            hero

            VStack(spacing: 14) {
                controlDeck
                statusPanel
                subtitlePanel
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background)
        .task(id: microphoneService.currentMicrophone?.id) {
            _ = microphoneService.currentMicrophone
        }
        .onAppear {
            FloatingLiveMeetingCaptionWindowManager.shared.syncVisibility(viewModel: viewModel)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    statusDot

                    Text(stateTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("实时会议字幕")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("系统输入音频流实时翻译成字幕，不保存音频文件。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 10) {
                microphoneSelector

                Text("目标：\(viewModel.targetLanguage.displayName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 34)
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
    }

    private var controlDeck: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                languageTile(
                    eyebrow: "输入语言",
                    title: "自动识别",
                    subtitle: "中文、英文、阿语",
                    systemImage: "sparkle.magnifyingglass"
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("目标语言")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $viewModel.targetLanguage) {
                        ForEach(RealTimeMeetingCaptionLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(quietSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            Divider()
                .padding(.vertical, 14)

            HStack(spacing: 14) {
                Button {
                    Task {
                        await LiveMeetingCaptionShortcutCoordinator.shared.toggle(viewModel: viewModel)
                    }
                } label: {
                    Label(
                        viewModel.isRunning ? "停止字幕" : "开始字幕",
                        systemImage: viewModel.isRunning ? "stop.fill" : "play.fill"
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 112)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(viewModel.isRunning ? .red : .accentColor)

                Text(helperText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                metricPill(title: "帧间隔", value: "\(viewModel.chunkDurationMS) ms")
                metricPill(title: "展示", value: "\(RealTimeMeetingCaptionViewModel.visibleSubtitleLimit) 条记录")
            }
        }
        .padding(16)
        .background(surface)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var statusPanel: some View {
        if case .failed(let message) = viewModel.state {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("连接失败")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)
                }

                DisclosureGroup(isExpanded: $isFailureDetailExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        diagnosticRow(title: "接口", value: "Azure AI Speech Translation")
                        diagnosticRow(title: "输入", value: "自动识别中文、英文、阿语")
                        diagnosticRow(title: "目标", value: viewModel.targetLanguage.displayName)
                        diagnosticRow(title: "处理", value: "确认 Azure Speech Key、Region 正确，且 Speech 资源已开通可用。")
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("展开排查信息")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.red)
                }
                .disclosureGroupStyle(.automatic)
            }
            .padding(14)
            .background(Color.red.opacity(colorScheme == .dark ? 0.16 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.red.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func diagnosticRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var microphoneSelector: some View {
        HStack(spacing: 10) {
            Image(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text("输入设备")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: microphoneSelection) {
                    if microphoneService.availableMicrophones.isEmpty {
                        Text("没有可用输入设备").tag("")
                    } else {
                        ForEach(microphoneService.availableMicrophones) { microphone in
                            Text(microphone.displayName).tag(microphone.id)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 194, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 248, alignment: .leading)
        .background(surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: { microphoneService.currentMicrophone?.id ?? "" },
            set: { selectedID in
                guard let microphone = microphoneService.availableMicrophones.first(where: { $0.id == selectedID }) else {
                    return
                }
                microphoneService.selectMicrophone(microphone)
            }
        )
    }

    private var subtitlePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("字幕流")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(viewModel.segments.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(quietSurface)
                    .clipShape(Capsule())

                Spacer()

                Button {
                    FloatingLiveMeetingCaptionWindowManager.shared.toggle(viewModel: viewModel)
                } label: {
                    Label("悬浮框", systemImage: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(quietSurface)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.clearSegments()
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(quietSurface)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isLogDrawerExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 11, weight: .semibold))
                        Text("日志")
                        Text("\(viewModel.logs.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Image(systemName: isLogDrawerExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(quietSurface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Text(viewModel.isRunning ? "实时更新" : "等待开始")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(viewModel.isRunning ? .green : .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if isLogDrawerExpanded {
                compactLogDrawer
                Divider()
            }

            subtitles
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(surface)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var subtitles: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.segments) { segment in
                    subtitleRow(segment)
                        .id(segment.id)
                }

                if viewModel.segments.isEmpty {
                    emptyState
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func subtitleRow(_ segment: RealTimeMeetingCaptionSegment) -> some View {
        let isArabic = (segment.targetLanguage ?? viewModel.targetLanguage) == .arabic
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text("#\(segment.id)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(segment.isFinal ? Color.green : Color.accentColor)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 36)
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 8) {
                Text(segment.translatedText.isEmpty ? "等待目标语言译文" : segment.translatedText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(isArabic ? .trailing : .leading)
                    .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
                    .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)

            }

            Spacer(minLength: 12)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(quietSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(quietSurface)
                    .frame(width: 72, height: 72)

                Image(systemName: "captions.bubble")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Text("等待字幕")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                Text("选择目标语言并开始后，实时转写和翻译会出现在这里。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 290)
    }

    private var compactLogDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.logs.isEmpty {
                Text("暂无日志")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.logs.suffix(5)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(logTimeFormatter.string(from: entry.timestamp))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .leading)

                        Text(entry.message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(quietSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.018))
    }

    private func languageTile(
        eyebrow: String,
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 42, height: 42)

                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(quietSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(quietSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var helperText: String {
        if viewModel.isRunning {
            return "正在从输入设备采集音频，并持续刷新字幕。"
        }

        if !viewModel.canStart {
            return "未检测到有道配置，点击开始后会提示你去设置中补全。"
        }

        return "输入语言自动识别，目标语言可随时调整。"
    }

    private var stateTitle: String {
        switch viewModel.state {
        case .idle:
            return "空闲"
        case .connecting:
            return "连接中"
        case .streaming:
            return "字幕生成中"
        case .stopping:
            return "停止中"
        case .failed:
            return "需要处理"
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle:
            return .secondary
        case .connecting, .stopping:
            return .orange
        case .streaming:
            return .green
        case .failed:
            return .red
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(statusColor.opacity(0.25), lineWidth: 6)
            }
    }

    private var background: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.055),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    private var surface: Color {
        colorScheme == .dark ? Color(NSColor.controlBackgroundColor) : .white
    }

    private var quietSurface: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color(red: 0.955, green: 0.965, blue: 0.975)
    }

    private var border: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 0.86, green: 0.88, blue: 0.92)
    }

    private var logTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    @ViewBuilder
    private var microphonePickerItems: some View {
        if microphoneService.availableMicrophones.isEmpty {
            Text("没有可用输入设备")
                .foregroundStyle(.secondary)
        } else {
            ForEach(microphoneService.availableMicrophones.filter(\.isBuiltIn)) { microphone in
                Button {
                    microphoneService.selectMicrophone(microphone)
                } label: {
                    if microphoneService.currentMicrophone?.id == microphone.id {
                        Label(microphone.displayName, systemImage: "checkmark")
                    } else {
                        Text(microphone.displayName)
                    }
                }
            }

            let external = microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
            if !external.isEmpty && !microphoneService.availableMicrophones.filter(\.isBuiltIn).isEmpty {
                Divider()
            }
            ForEach(external) { microphone in
                Button {
                    microphoneService.selectMicrophone(microphone)
                } label: {
                    if microphoneService.currentMicrophone?.id == microphone.id {
                        Label(microphone.displayName, systemImage: "checkmark")
                    } else {
                        Text(microphone.displayName)
                    }
                }
            }
        }
    }
}
