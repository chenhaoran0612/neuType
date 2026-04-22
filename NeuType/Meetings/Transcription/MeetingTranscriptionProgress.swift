import Foundation

struct MeetingTranscriptionProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparingAudio
        case analyzingAudio
        case uploadingAudio
        case waitingForRemoteResult
        case transcribing
        case finalizing
    }

    let stage: Stage
    let fractionCompleted: Float
    let message: String
    let completedUnitCount: Int
    let totalUnitCount: Int

    static func preparingAudio() -> MeetingTranscriptionProgress {
        MeetingTranscriptionProgress(
            stage: .preparingAudio,
            fractionCompleted: 0.04,
            message: "正在准备音频\n读取会议录音并检查格式…",
            completedUnitCount: 0,
            totalUnitCount: 0
        )
    }

    static func analyzingAudio(
        estimatedChunkCount: Int,
        chunkDuration: TimeInterval
    ) -> MeetingTranscriptionProgress {
        MeetingTranscriptionProgress(
            stage: .analyzingAudio,
            fractionCompleted: 0.12,
            message: "正在分析并切分音频\n预计切分为 \(estimatedChunkCount) 段 · 每段约 \(Int(chunkDuration.rounded())) 秒",
            completedUnitCount: 0,
            totalUnitCount: max(estimatedChunkCount, 0)
        )
    }

    static func uploadingAudio(chunkIndex: Int, totalChunks: Int) -> MeetingTranscriptionProgress {
        let safeTotal = max(totalChunks, 1)
        let fraction = 0.14 + (Float(max(chunkIndex - 1, 0)) / Float(safeTotal)) * 0.06
        return MeetingTranscriptionProgress(
            stage: .uploadingAudio,
            fractionCompleted: fraction,
            message: "正在上传分段音频\n准备发送 \(min(chunkIndex, safeTotal)) / \(safeTotal) 段…",
            completedUnitCount: max(chunkIndex - 1, 0),
            totalUnitCount: safeTotal
        )
    }

    static func transcribing(
        chunkIndex: Int,
        totalChunks: Int,
        chunkStartTime: TimeInterval,
        chunkEndTime: TimeInterval
    ) -> MeetingTranscriptionProgress {
        let safeTotal = max(totalChunks, 1)
        let completed = min(max(chunkIndex - 1, 0), safeTotal)
        let fraction = 0.2 + (Float(completed) / Float(safeTotal)) * 0.7
        return MeetingTranscriptionProgress(
            stage: .transcribing,
            fractionCompleted: fraction,
            message: "正在转写 \(min(chunkIndex, safeTotal)) / \(safeTotal) 段\n时间范围 \(Self.formatTimestamp(chunkStartTime)) - \(Self.formatTimestamp(chunkEndTime))",
            completedUnitCount: completed,
            totalUnitCount: safeTotal
        )
    }

    static func finalizing() -> MeetingTranscriptionProgress {
        MeetingTranscriptionProgress(
            stage: .finalizing,
            fractionCompleted: 0.94,
            message: "正在合并与整理结果\n去重重叠片段并修正时间轴…",
            completedUnitCount: 0,
            totalUnitCount: 0
        )
    }

    static func waitingForRemoteResult() -> MeetingTranscriptionProgress {
        MeetingTranscriptionProgress(
            stage: .waitingForRemoteResult,
            fractionCompleted: 0.72,
            message: "服务端处理中\n正在等待远端转写结果返回…",
            completedUnitCount: 0,
            totalUnitCount: 0
        )
    }

    private static func formatTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
