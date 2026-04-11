import Foundation
import GRDB

final class MeetingRecordStore: ObservableObject {
    static let shared = try! MeetingRecordStore()

    private let dbQueue: DatabaseQueue

    init(path: String? = nil) throws {
        if let path {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: path)
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "NeuType"
            let appDirectory = applicationSupport.appendingPathComponent(bundleID)
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            let dbPath = appDirectory.appendingPathComponent("meetings.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath)
        }

        try setupDatabase()
    }

    static func inMemory() throws -> MeetingRecordStore {
        try MeetingRecordStore(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try setupDatabase()
    }

    private nonisolated func setupDatabase() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_meeting_tables") { db in
            try db.create(table: MeetingRecord.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("audioFileName", .text).notNull()
                t.column("transcriptPreview", .text).notNull().defaults(to: "")
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("progress", .double).notNull().defaults(to: 0)
            }

            try db.create(table: MeetingTranscriptSegment.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("meetingID", .text)
                    .notNull()
                    .indexed()
                    .references(MeetingRecord.databaseTableName, onDelete: .cascade)
                t.column("sequence", .integer).notNull()
                t.column("speakerLabel", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("text", .text).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }

    nonisolated func insertMeeting(
        _ meeting: MeetingRecord,
        segments: [MeetingTranscriptSegment]
    ) async throws {
        try await dbQueue.write { db in
            try meeting.insert(db)
            for segment in segments {
                try segment.insert(db)
            }
        }
    }

    nonisolated func fetchMeeting(id: UUID) async throws -> MeetingRecord? {
        try await dbQueue.read { db in
            try MeetingRecord
                .filter(MeetingRecord.Columns.id == id)
                .fetchOne(db)
        }
    }

    nonisolated func fetchSegments(meetingID: UUID) async throws -> [MeetingTranscriptSegment] {
        try await dbQueue.read { db in
            try MeetingTranscriptSegment
                .filter(MeetingTranscriptSegment.Columns.meetingID == meetingID)
                .order(MeetingTranscriptSegment.Columns.sequence.asc)
                .fetchAll(db)
        }
    }

    nonisolated func updateTranscription(
        meetingID: UUID,
        fullText: String,
        segments: [MeetingTranscriptionSegmentPayload]
    ) async throws {
        try await dbQueue.write { db in
            _ = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .updateAll(db, [
                    MeetingRecord.Columns.transcriptPreview.set(to: fullText),
                    MeetingRecord.Columns.status.set(to: MeetingRecordStatus.completed.rawValue),
                    MeetingRecord.Columns.progress.set(to: 1.0),
                ])

            try MeetingTranscriptSegment
                .filter(MeetingTranscriptSegment.Columns.meetingID == meetingID)
                .deleteAll(db)

            for payload in segments {
                let segment = MeetingTranscriptSegment(
                    id: UUID(),
                    meetingID: meetingID,
                    sequence: payload.sequence,
                    speakerLabel: payload.speakerLabel,
                    startTime: payload.startTime,
                    endTime: payload.endTime,
                    text: payload.text
                )
                try segment.insert(db)
            }
        }
    }
}
