import Foundation
import GRDB

final class MeetingRecordStore: ObservableObject {
    static let shared = makeShared()
    private(set) static var sharedBootstrapDescription = "uninitialized"
    private(set) static var sharedBootstrapFailure: String?

    private let dbQueue: DatabaseQueue
    private let databasePath: String
    private let staleProcessingCutoff: Date

    init(path: String? = nil) throws {
        staleProcessingCutoff = Date()
        if let path {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            databasePath = path
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                MeetingLog.error("MeetingRecordStore create directory failed path=\(directory.path) error=\(error.localizedDescription)")
                throw error
            }

            do {
                dbQueue = try DatabaseQueue(path: path)
            } catch {
                MeetingLog.error("MeetingRecordStore open database failed path=\(path) error=\(error.localizedDescription)")
                throw error
            }
        } else {
            let dbPath = try Self.primaryDatabaseURL().path
            let directory = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            databasePath = dbPath
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                MeetingLog.error("MeetingRecordStore create default directory failed path=\(directory.path) error=\(error.localizedDescription)")
                throw error
            }

            do {
                dbQueue = try DatabaseQueue(path: dbPath)
            } catch {
                MeetingLog.error("MeetingRecordStore open default database failed path=\(dbPath) error=\(error.localizedDescription)")
                throw error
            }
        }

        do {
            try setupDatabase()
        } catch {
            MeetingLog.error("MeetingRecordStore migrate failed path=\(databasePath) error=\(error.localizedDescription)")
            throw error
        }

        do {
            try repairStaleProcessingMeetings()
        } catch {
            MeetingLog.error("MeetingRecordStore stale repair failed path=\(databasePath) error=\(error.localizedDescription)")
            throw error
        }

        MeetingLog.info("MeetingRecordStore initialized path=\(databasePath)")
    }

    static func inMemory() throws -> MeetingRecordStore {
        try MeetingRecordStore(dbQueue: DatabaseQueue())
    }

    static func inMemory(seed meetings: [MeetingRecord]) throws -> MeetingRecordStore {
        let store = try MeetingRecordStore(dbQueue: DatabaseQueue())
        for meeting in meetings {
            try store.dbQueue.write { db in
                try meeting.insert(db)
            }
        }
        return store
    }

    private init(dbQueue: DatabaseQueue) throws {
        staleProcessingCutoff = Date()
        databasePath = "in-memory"
        self.dbQueue = dbQueue
        try setupDatabase()
        try repairStaleProcessingMeetings()
        MeetingLog.info("MeetingRecordStore initialized path=in-memory")
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
                t.column("summaryStatus", .text).notNull().defaults(to: MeetingSummaryStatus.unsubmitted.rawValue)
                t.column("summaryExternalMeetingID", .text).notNull().defaults(to: "")
                t.column("summaryJobID", .text).notNull().defaults(to: "")
                t.column("summaryTaskID", .text).notNull().defaults(to: "")
                t.column("summaryPollURL", .text).notNull().defaults(to: "")
                t.column("summaryText", .text).notNull().defaults(to: "")
                t.column("summaryFullText", .text).notNull().defaults(to: "")
                t.column("summaryResultJSON", .text).notNull().defaults(to: "")
                t.column("summaryShareURL", .text).notNull().defaults(to: "")
                t.column("summaryErrorMessage", .text).notNull().defaults(to: "")
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

        migrator.registerMigration("v2_add_meeting_summary_columns") { db in
            let columns = try db.columns(in: MeetingRecord.databaseTableName).map(\.name)
            let defaultColumns: [(String, Database.ColumnType, DatabaseValueConvertible)] = [
                ("summaryStatus", .text, MeetingSummaryStatus.unsubmitted.rawValue),
                ("summaryExternalMeetingID", .text, ""),
                ("summaryJobID", .text, ""),
                ("summaryTaskID", .text, ""),
                ("summaryPollURL", .text, ""),
                ("summaryText", .text, ""),
                ("summaryFullText", .text, ""),
                ("summaryResultJSON", .text, ""),
                ("summaryShareURL", .text, ""),
                ("summaryErrorMessage", .text, ""),
            ]

            for (name, type, value) in defaultColumns where !columns.contains(name) {
                try db.alter(table: MeetingRecord.databaseTableName) { table in
                    table.add(column: name, type).notNull().defaults(to: value)
                }
            }
        }

        migrator.registerMigration("v3_add_meeting_summary_full_text") { db in
            let columns = try db.columns(in: MeetingRecord.databaseTableName).map(\.name)
            guard !columns.contains("summaryFullText") else { return }
            try db.alter(table: MeetingRecord.databaseTableName) { table in
                table.add(column: "summaryFullText", .text).notNull().defaults(to: "")
            }
        }

        try migrator.migrate(dbQueue)
    }

    private nonisolated func repairStaleProcessingMeetings() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE \(MeetingRecord.databaseTableName)
                SET
                    status = ?,
                    progress = 0,
                    transcriptPreview = ''
                WHERE
                    status = ?
                    AND createdAt < ?
                    AND NOT EXISTS (
                        SELECT 1
                        FROM \(MeetingTranscriptSegment.databaseTableName)
                        WHERE \(MeetingTranscriptSegment.databaseTableName).meetingID = \(MeetingRecord.databaseTableName).id
                    )
                """,
                arguments: [
                    MeetingRecordStatus.unprocessed.rawValue,
                    MeetingRecordStatus.processing.rawValue,
                    staleProcessingCutoff,
                ]
            )
        }
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
        postMeetingRecordsDidChange()
    }

    nonisolated func fetchMeeting(id: UUID) async throws -> MeetingRecord? {
        return try await dbQueue.read { db in
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

    nonisolated func fetchMeetings() async throws -> [MeetingRecord] {
        return try await dbQueue.read { db in
            try MeetingRecord
                .order(MeetingRecord.Columns.createdAt.desc)
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
        postMeetingRecordsDidChange()
    }

    nonisolated func updateMeetingStatus(
        meetingID: UUID,
        status: MeetingRecordStatus,
        progress: Float,
        transcriptPreview: String? = nil
    ) async throws {
        let didChange = try await dbQueue.write { db -> Bool in
            guard let current = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .fetchOne(db) else {
                return false
            }

            var assignments: [ColumnAssignment] = [
                MeetingRecord.Columns.status.set(to: status.rawValue),
                MeetingRecord.Columns.progress.set(to: progress),
            ]
            var hasChanges = current.status != status || current.progress != progress

            if let transcriptPreview {
                hasChanges = hasChanges || current.transcriptPreview != transcriptPreview
                assignments.append(MeetingRecord.Columns.transcriptPreview.set(to: transcriptPreview))
            }

            guard hasChanges else { return false }

            _ = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .updateAll(db, assignments)
            return true
        }
        if didChange {
            postMeetingRecordsDidChange()
        }
    }

    nonisolated func updateMeetingTitle(
        meetingID: UUID,
        title: String
    ) async throws {
        try await dbQueue.write { db in
            _ = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .updateAll(db, [
                    MeetingRecord.Columns.title.set(to: title),
                ])
        }
        postMeetingRecordsDidChange()
    }

    nonisolated func updateSummarySubmission(
        meetingID: UUID,
        status: MeetingSummaryStatus,
        externalMeetingID: String,
        jobID: String,
        taskID: String,
        pollURL: String
    ) async throws {
        let didChange = try await dbQueue.write { db -> Bool in
            guard let current = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .fetchOne(db) else {
                return false
            }

            let hasChanges =
                current.summaryStatus != status
                || current.summaryExternalMeetingID != externalMeetingID
                || current.summaryJobID != jobID
                || current.summaryTaskID != taskID
                || current.summaryPollURL != pollURL
                || !current.summaryErrorMessage.isEmpty

            guard hasChanges else { return false }

            _ = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .updateAll(db, [
                    MeetingRecord.Columns.summaryStatus.set(to: status.rawValue),
                    MeetingRecord.Columns.summaryExternalMeetingID.set(to: externalMeetingID),
                    MeetingRecord.Columns.summaryJobID.set(to: jobID),
                    MeetingRecord.Columns.summaryTaskID.set(to: taskID),
                    MeetingRecord.Columns.summaryPollURL.set(to: pollURL),
                    MeetingRecord.Columns.summaryErrorMessage.set(to: ""),
                ])
            return true
        }
        if didChange {
            postMeetingRecordsDidChange()
        }
    }

    nonisolated func updateSummaryStatus(
        meetingID: UUID,
        status: MeetingSummaryStatus,
        errorMessage: String = ""
    ) async throws {
        let didChange = try await dbQueue.write { db -> Bool in
            guard let current = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .fetchOne(db) else {
                return false
            }

            guard current.summaryStatus != status || current.summaryErrorMessage != errorMessage else {
                return false
            }

            _ = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .updateAll(db, [
                    MeetingRecord.Columns.summaryStatus.set(to: status.rawValue),
                    MeetingRecord.Columns.summaryErrorMessage.set(to: errorMessage),
                ])
            return true
        }
        if didChange {
            postMeetingRecordsDidChange()
        }
    }

    nonisolated func updateSummaryResult(
        meetingID: UUID,
        summaryText: String,
        fullText: String,
        result: MeetingSummaryResult,
        shareURL: String
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let resultJSON = String(decoding: try encoder.encode(result), as: UTF8.self)

        let didChange = try await dbQueue.write { db -> Bool in
            guard let current = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .fetchOne(db) else {
                return false
            }

            let hasChanges =
                current.summaryStatus != .completed
                || current.summaryText != summaryText
                || current.summaryFullText != fullText
                || current.summaryResultJSON != resultJSON
                || current.summaryShareURL != shareURL
                || !current.summaryErrorMessage.isEmpty

            guard hasChanges else { return false }

            _ = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .updateAll(db, [
                    MeetingRecord.Columns.summaryStatus.set(to: MeetingSummaryStatus.completed.rawValue),
                    MeetingRecord.Columns.summaryText.set(to: summaryText),
                    MeetingRecord.Columns.summaryFullText.set(to: fullText),
                    MeetingRecord.Columns.summaryResultJSON.set(to: resultJSON),
                    MeetingRecord.Columns.summaryShareURL.set(to: shareURL),
                    MeetingRecord.Columns.summaryErrorMessage.set(to: ""),
                ])
            return true
        }
        if didChange {
            postMeetingRecordsDidChange()
        }
    }

    nonisolated func deleteMeeting(meetingID: UUID) async throws {
        let audioFileName = try await dbQueue.write { db -> String? in
            let audioFileName = try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .fetchOne(db)?
                .audioFileName

            try MeetingRecord
                .filter(MeetingRecord.Columns.id == meetingID)
                .deleteAll(db)

            return audioFileName
        }

        if let audioFileName {
            let audioURL = MeetingRecord.meetingsDirectory.appendingPathComponent(audioFileName)
            try? FileManager.default.removeItem(at: audioURL)
        }

        postMeetingRecordsDidChange()
    }

    private nonisolated func postMeetingRecordsDidChange() {
        NotificationCenter.default.post(name: .meetingRecordsDidChange, object: nil)
    }

    private static func makeShared() -> MeetingRecordStore {
        let primaryPath: String
        do {
            primaryPath = try primaryDatabaseURL().path
            let store = try MeetingRecordStore(path: primaryPath)
            sharedBootstrapDescription = "primary:\(primaryPath)"
            return store
        } catch {
            let attemptedPath = (try? primaryDatabaseURL().path) ?? "unknown"
            let message = "MeetingRecordStore shared init failed mode=primary path=\(attemptedPath) error=\(error.localizedDescription)"
            sharedBootstrapFailure = message
            MeetingLog.error(message)
        }

        let recoveryPath = recoveryDatabaseURL().path
        do {
            let store = try MeetingRecordStore(path: recoveryPath)
            sharedBootstrapDescription = "recovery:\(recoveryPath)"
            MeetingLog.error("MeetingRecordStore recovery database activated path=\(recoveryPath)")
            return store
        } catch {
            let message = "MeetingRecordStore shared init failed mode=recovery path=\(recoveryPath) error=\(error.localizedDescription)"
            sharedBootstrapFailure = [sharedBootstrapFailure, message]
                .compactMap { $0 }
                .joined(separator: " | ")
            MeetingLog.error(message)
        }

        do {
            let store = try MeetingRecordStore(dbQueue: DatabaseQueue())
            sharedBootstrapDescription = "in-memory"
            MeetingLog.error("MeetingRecordStore falling back to in-memory store")
            return store
        } catch {
            let message = "MeetingRecordStore shared init failed mode=in-memory error=\(error.localizedDescription)"
            sharedBootstrapFailure = [sharedBootstrapFailure, message]
                .compactMap { $0 }
                .joined(separator: " | ")
            MeetingLog.error(message)
            preconditionFailure(message)
        }
    }

    private static func primaryDatabaseURL() throws -> URL {
        try defaultApplicationSupportDirectory().appendingPathComponent("meetings.sqlite")
    }

    private static func recoveryDatabaseURL() -> URL {
        let baseDirectory = (try? defaultApplicationSupportDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory.appendingPathComponent("meetings.recovery.sqlite")
    }

    private static func defaultApplicationSupportDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MeetingRecordStoreBootstrapError.missingApplicationSupportDirectory
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "NeuType"
        return applicationSupport.appendingPathComponent(bundleID)
    }
}

enum MeetingRecordStoreBootstrapError: LocalizedError {
    case missingApplicationSupportDirectory

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            return "Application Support directory is unavailable."
        }
    }
}
