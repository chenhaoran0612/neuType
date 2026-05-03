import AppKit
import SwiftUI

@MainActor
final class FloatingLiveMeetingCaptionWindowManager {
    static let shared = FloatingLiveMeetingCaptionWindowManager()

    private var window: FloatingLiveMeetingCaptionPanel?

    private init() {}

    func toggle(viewModel: RealTimeMeetingCaptionViewModel) {
        if let window, window.isVisible {
            hide()
        } else {
            show(viewModel: viewModel)
        }
    }

    func show(viewModel: RealTimeMeetingCaptionViewModel, activate: Bool = true) {
        let window = ensureWindow()
        window.contentView = FloatingCaptionDragHostingView(
            rootView: FloatingLiveMeetingCaptionView(
                viewModel: viewModel,
                onClose: { [weak self, weak viewModel] in
                    Task { @MainActor in
                        await viewModel?.stop()
                        self?.hide()
                    }
                }
            )
        )

        if !window.isVisible {
            position(window: window)
        }

        window.orderFrontRegardless()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func syncVisibility(viewModel: RealTimeMeetingCaptionViewModel) {
        guard let window, window.isVisible else { return }
        window.contentView = FloatingCaptionDragHostingView(
            rootView: FloatingLiveMeetingCaptionView(
                viewModel: viewModel,
                onClose: { [weak self, weak viewModel] in
                    Task { @MainActor in
                        await viewModel?.stop()
                        self?.hide()
                    }
                }
            )
        )
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() -> FloatingLiveMeetingCaptionPanel {
        if let window {
            return window
        }

        let panel = FloatingLiveMeetingCaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        self.window = panel
        return panel
    }

    private func position(window: NSWindow) {
        let size = window.frame.size
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - size.width - 24
        let y = visibleFrame.maxY - size.height - 24
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

final class FloatingLiveMeetingCaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FloatingCaptionDragHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct FloatingLiveMeetingCaptionView: View {
    @ObservedObject var viewModel: RealTimeMeetingCaptionViewModel
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            subtitleList
        }
        .padding(14)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(8)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("实时会议字幕")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(RealTimeMeetingCaptionViewModel.visibleSubtitleLimit) 条记录 · \(viewModel.targetLanguage.displayName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: {
                viewModel.clearSegments()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(quietSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(quietSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitleList: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.segments) { segment in
                    let isArabic = (segment.targetLanguage ?? viewModel.targetLanguage) == .arabic
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("#\(segment.id)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Text(segment.translatedText.isEmpty ? "等待目标语言译文" : segment.translatedText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(isArabic ? .trailing : .leading)
                                .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
                                .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
                                .fixedSize(horizontal: false, vertical: true)

                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(quietSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if viewModel.segments.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("等待字幕")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("开始后，最新字幕会显示在最上面。")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
    }

    private var background: some View {
        Color(NSColor.windowBackgroundColor)
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
}
