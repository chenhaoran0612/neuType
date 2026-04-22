import Foundation

enum UploadStatus: String, Codable, Equatable, Sendable {
    case pending
    case uploaded
    case failedToUpload = "failed_to_upload"
    case failedConflict = "failed_conflict"
}

struct MeetingUploadChunkRecord: Codable, Equatable, Sendable {
    let index: Int
    let startMS: Int
    let endMS: Int
    let sha256: String
    let localFilePath: String
    var uploadStatus: UploadStatus

    enum CodingKeys: String, CodingKey {
        case index
        case startMS = "start_ms"
        case endMS = "end_ms"
        case sha256
        case localFilePath = "local_file_path"
        case uploadStatus = "upload_status"
    }

    init(
        index: Int,
        startMS: Int,
        endMS: Int,
        sha256: String,
        localFilePath: String,
        uploadStatus: UploadStatus = .pending
    ) {
        self.index = index
        self.startMS = startMS
        self.endMS = endMS
        self.sha256 = sha256
        self.localFilePath = localFilePath
        self.uploadStatus = uploadStatus
    }
}

final class MeetingUploadLedger: @unchecked Sendable {
    enum Strategy: String, Codable, Equatable, Sendable {
        case liveChunks = "live_chunks"
        case fullAudioFallback = "full_audio_fallback"
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var remoteSessionID: String?
        var clientSessionToken: String
        var meetingRecordID: String?
        var fullAudioLocalPath: String?
        var chunks: [MeetingUploadChunkRecord]
        var finalizeRequested: Bool
        var selectedStrategy: Strategy?

        enum CodingKeys: String, CodingKey {
            case remoteSessionID = "remote_session_id"
            case clientSessionToken = "client_session_token"
            case meetingRecordID = "meeting_record_id"
            case fullAudioLocalPath = "full_audio_local_path"
            case chunks
            case finalizeRequested = "finalize_requested"
            case selectedStrategy = "selected_strategy"
        }
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private var storage: Snapshot

    static func inMemory(
        clientSessionToken: String = UUID().uuidString,
        remoteSessionID: String? = nil,
        meetingRecordID: UUID? = nil
    ) -> MeetingUploadLedger {
        MeetingUploadLedger(
            fileURL: nil,
            snapshot: Snapshot(
                remoteSessionID: remoteSessionID,
                clientSessionToken: clientSessionToken,
                meetingRecordID: meetingRecordID?.uuidString,
                fullAudioLocalPath: nil,
                chunks: [],
                finalizeRequested: false,
                selectedStrategy: nil
            )
        )
    }

    static func persisted(
        fileURL: URL,
        clientSessionToken: String = UUID().uuidString,
        remoteSessionID: String? = nil,
        meetingRecordID: UUID? = nil
    ) throws -> MeetingUploadLedger {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return MeetingUploadLedger(fileURL: fileURL, snapshot: snapshot)
        }

        return MeetingUploadLedger(
            fileURL: fileURL,
            snapshot: Snapshot(
                remoteSessionID: remoteSessionID,
                clientSessionToken: clientSessionToken,
                meetingRecordID: meetingRecordID?.uuidString,
                fullAudioLocalPath: nil,
                chunks: [],
                finalizeRequested: false,
                selectedStrategy: nil
            )
        )
    }

    private init(fileURL: URL?, snapshot: Snapshot) {
        self.fileURL = fileURL
        self.storage = snapshot
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var requiresFullAudioFallback: Bool {
        requiresFullAudioFallback(expectedChunkCount: nil)
    }

    func requiresFullAudioFallback(expectedChunkCount: Int?) -> Bool {
        let snapshot = snapshot
        if snapshot.selectedStrategy == .fullAudioFallback {
            return true
        }
        if snapshot.chunks.isEmpty {
            return true
        }
        if snapshot.chunks.contains(where: { $0.uploadStatus != .uploaded }) {
            return true
        }
        if let expectedChunkCount, expectedChunkCount > 0 {
            let uploadedIndexes = Set(
                snapshot.chunks
                    .filter { $0.uploadStatus == .uploaded }
                    .map(\.index)
            )
            let expectedIndexes = Set(0..<expectedChunkCount)
            if uploadedIndexes != expectedIndexes {
                return true
            }
        }
        return false
    }

    func recordChunk(_ record: MeetingUploadChunkRecord) throws {
        try mutate { snapshot in
            if let existingIndex = snapshot.chunks.firstIndex(where: { $0.index == record.index }) {
                var updatedRecord = record
                if snapshot.chunks[existingIndex].uploadStatus == .uploaded,
                   record.uploadStatus == .pending {
                    updatedRecord.uploadStatus = .uploaded
                }
                snapshot.chunks[existingIndex] = updatedRecord
            } else {
                snapshot.chunks.append(record)
                snapshot.chunks.sort { $0.index < $1.index }
            }
        }
    }

    func markChunkUploaded(index: Int) throws {
        try updateChunk(index: index) { $0.uploadStatus = .uploaded }
    }

    func markChunkUploadFailed(index: Int, conflict: Bool = false) throws {
        try updateChunk(index: index) {
            $0.uploadStatus = conflict ? .failedConflict : .failedToUpload
        }
    }

    func updateRemoteSessionID(_ remoteSessionID: String) throws {
        try mutate { $0.remoteSessionID = remoteSessionID }
    }

    func updateFullAudioLocalPath(_ path: String) throws {
        try mutate { $0.fullAudioLocalPath = path }
    }

    func updateMeetingRecordID(_ meetingRecordID: UUID) throws {
        try mutate { $0.meetingRecordID = meetingRecordID.uuidString }
    }

    func setSelectedStrategy(_ strategy: Strategy) throws {
        try mutate { $0.selectedStrategy = strategy }
    }

    func markFinalizeRequested() throws {
        try mutate { $0.finalizeRequested = true }
    }

    func resetForRetry(clientSessionToken: String) throws {
        try mutate { snapshot in
            snapshot.remoteSessionID = nil
            snapshot.clientSessionToken = clientSessionToken
            snapshot.fullAudioLocalPath = nil
            snapshot.chunks = []
            snapshot.finalizeRequested = false
            snapshot.selectedStrategy = nil
        }
    }

    private func updateChunk(index: Int, mutation: (inout MeetingUploadChunkRecord) -> Void) throws {
        try mutate { snapshot in
            guard let chunkIndex = snapshot.chunks.firstIndex(where: { $0.index == index }) else {
                return
            }
            mutation(&snapshot.chunks[chunkIndex])
        }
    }

    private func mutate(_ mutation: (inout Snapshot) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try mutation(&storage)
        try persistLocked()
    }

    private func persistLocked() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storage)
        try data.write(to: fileURL, options: .atomic)
    }
}
