import Foundation
import NovPoolCore

/// `sync_outbox_jobs` table read and write: persistent primitive for the transactional outbox.
///
/// Key design: Tasks and their dependencies are all stored in the database (`dependsOnJobID`), enabling cross-cloud cascading
/// "First upload to a cloud drive to get an external link, then write in Notion" still holds true after the process restarts.
public struct OutboxRepository: Sendable {
    private let database: NovPoolDatabase

    public init(database: NovPoolDatabase) {
        self.database = database
    }

    private static let columns = """
        jobID, itemID, connectorID, dependsOnJobID, status, retryCount, nextRetryAt, \
        lastError, remoteItemID, remoteWebURL, updatedAt
        """

    // MARK: - write

    @discardableResult
    public func enqueue(
        itemID: UUID,
        connectorID: String,
        dependsOnJobID: UUID? = nil,
        now: Date = Date()
    ) async throws -> UUID {
        let job = OutboxJobRecord(
            itemID: itemID,
            connectorID: connectorID,
            dependsOnJobID: dependsOnJobID,
            status: dependsOnJobID == nil ? .pending : .blocked,
            nextRetryAt: now,
            updatedAt: now
        )
        try await database.execute(
            """
            INSERT INTO sync_outbox_jobs (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(job.id.uuidString),
                .text(job.itemID.uuidString),
                .text(job.connectorID),
                job.dependsOnJobID.map { SQLValue.text($0.uuidString) } ?? .null,
                .text(job.status.rawValue),
                .integer(Int64(job.retryCount)),
                .date(job.nextRetryAt),
                .null,
                .null,
                .null,
                .date(job.updatedAt),
            ]
        )
        return job.id
    }

    public func markRunning(id: UUID, now: Date = Date()) async throws {
        try await update(id: id, now: now) { job in
            job.status = .running
            job.updatedAt = now
        }
    }

    public func markSucceeded(id: UUID, receipt: RemoteReceipt, now: Date = Date()) async throws {
        try await update(id: id, now: now) { job in
            job.status = .succeeded
            job.remoteItemID = receipt.remoteItemID
            job.remoteWebURL = receipt.remoteWebURL.absoluteString
            job.lastError = nil
            job.updatedAt = now
        }
    }

    public func markFailed(
        id: UUID,
        error: String,
        retryCount: Int,
        nextRetryAt: Date,
        now: Date = Date()
    ) async throws {
        try await update(id: id, now: now) { job in
            job.status = .pending
            job.retryCount = retryCount
            job.nextRetryAt = nextRetryAt
            job.lastError = error
            job.updatedAt = now
        }
    }

    /// Retry attempts exhausted: terminate this task and retain the Errors information for diagnosis.
    public func markAbandoned(id: UUID, error: String, now: Date = Date()) async throws {
        try await update(id: id, now: now) { job in
            job.status = .failed
            job.lastError = error
            job.updatedAt = now
        }
    }

    public func markBlocked(id: UUID, dependsOnJobID: UUID, now: Date = Date()) async throws {
        try await update(id: id, now: now) { job in
            job.status = .blocked
            job.dependsOnJobID = dependsOnJobID
            job.updatedAt = now
        }
    }

    /// After the prerequisite task is completed successfully, the downstream task is unlocked (BLOCKED → PENDING).
    @discardableResult
    public func releaseDependents(ofJobID jobID: UUID, now: Date = Date()) async throws -> [UUID] {
        let ids = try await database.query(
            "SELECT jobID FROM sync_outbox_jobs WHERE dependsOnJobID = ? AND status = ?",
            [.text(jobID.uuidString), .text(OutboxJobRecord.Status.blocked.rawValue)]
        ).compactMap { $0.text("jobID").flatMap(UUID.init(uuidString:)) }

        for id in ids {
            try await update(id: id, now: now) { job in
                job.status = .pending
                job.nextRetryAt = now
                job.updatedAt = now
            }
        }
        return ids
    }

    // MARK: - read

    /// For pending actions: PENDING and `nextRetryAt <= now`, sort by due time.
    public func dueJobs(now: Date = Date(), limit: Int = 20) async throws -> [OutboxJobRecord] {
        let rows = try await database.query(
            """
            SELECT \(Self.columns) FROM sync_outbox_jobs
            WHERE status = ? AND nextRetryAt <= ?
            ORDER BY nextRetryAt ASC, rowid ASC
            LIMIT ?
            """,
            [
                .text(OutboxJobRecord.Status.pending.rawValue),
                .date(now),
                .integer(Int64(limit)),
            ]
        )
        return try rows.map(Self.decode)
    }

    public func fetch(id: UUID) async throws -> OutboxJobRecord? {
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM sync_outbox_jobs WHERE jobID = ?",
            [.text(id.uuidString)]
        )
        return try rows.first.map(Self.decode)
    }

    public func jobs(forItem itemID: UUID) async throws -> [OutboxJobRecord] {
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM sync_outbox_jobs WHERE itemID = ? ORDER BY updatedAt ASC, rowid ASC",
            [.text(itemID.uuidString)]
        )
        return try rows.map(Self.decode)
    }

    public func statusCounts() async throws -> [OutboxJobRecord.Status: Int] {
        let rows = try await database.query(
            "SELECT status, COUNT(*) AS value FROM sync_outbox_jobs GROUP BY status"
        )
        var counts: [OutboxJobRecord.Status: Int] = [:]
        for row in rows {
            guard let raw = row.text("status"),
                  let status = OutboxJobRecord.Status(rawValue: raw) else { continue }
            counts[status] = Int(row.int("value") ?? 0)
        }
        return counts
    }

    /// Clear completed tasks (keep for N days, used for cache cleaning in the settings panel).
    @discardableResult
    public func pruneFinished(olderThan cutoff: Date) async throws -> Int {
        try await database.execute(
            "DELETE FROM sync_outbox_jobs WHERE status = ? AND updatedAt < ?",
            [.text(OutboxJobRecord.Status.succeeded.rawValue), .date(cutoff)]
        )
    }

    /// When a prerequisite task permanently fails, terminate the tasks that depend on it as well—otherwise, they will be stuck in BLOCKED forever.
    /// A batch of zombie tasks that will never be taken out remains in the queue.
    @discardableResult
    public func failDependents(
        ofJobID jobID: UUID,
        reason: String,
        now: Date = Date()
    ) async throws -> [UUID] {
        let ids = try await database.query(
            """
            SELECT jobID FROM sync_outbox_jobs
            WHERE dependsOnJobID = ? AND status IN (?, ?)
            """,
            [
                .text(jobID.uuidString),
                .text(OutboxJobRecord.Status.blocked.rawValue),
                .text(OutboxJobRecord.Status.pending.rawValue),
            ]
        ).compactMap { $0.text("jobID").flatMap(UUID.init(uuidString:)) }

        for id in ids {
            try await update(id: id, now: now) { job in
                job.status = .failed
                job.lastError = reason
                job.updatedAt = now
            }
        }
        return ids
    }

    // MARK: - Internals

    private func update(
        id: UUID,
        now: Date,
        _ mutate: (inout OutboxJobRecord) -> Void
    ) async throws {
        guard var job = try await fetch(id: id) else {
            throw NovPoolError.database("Outbox job not found: \(id.uuidString)")
        }
        mutate(&job)
        try await database.execute(
            """
            UPDATE sync_outbox_jobs SET
                status = ?, retryCount = ?, nextRetryAt = ?, lastError = ?,
                remoteItemID = ?, remoteWebURL = ?, dependsOnJobID = ?, updatedAt = ?
            WHERE jobID = ?
            """,
            [
                .text(job.status.rawValue),
                .integer(Int64(job.retryCount)),
                .date(job.nextRetryAt),
                job.lastError.map { SQLValue.text($0) } ?? .null,
                job.remoteItemID.map { SQLValue.text($0) } ?? .null,
                job.remoteWebURL.map { SQLValue.text($0) } ?? .null,
                job.dependsOnJobID.map { SQLValue.text($0.uuidString) } ?? .null,
                .date(now),
                .text(id.uuidString),
            ]
        )
    }

    static func decode(_ row: SQLRow) throws -> OutboxJobRecord {
        guard let idText = row.text("jobID"), let id = UUID(uuidString: idText),
              let itemText = row.text("itemID"), let itemID = UUID(uuidString: itemText),
              let connectorID = row.text("connectorID"),
              let statusRaw = row.text("status"),
              let status = OutboxJobRecord.Status(rawValue: statusRaw) else {
            throw NovPoolError.database("Illegal sync_outbox_jobs row")
        }
        return OutboxJobRecord(
            id: id,
            itemID: itemID,
            connectorID: connectorID,
            dependsOnJobID: row.text("dependsOnJobID").flatMap(UUID.init(uuidString:)),
            status: status,
            retryCount: Int(row.int("retryCount") ?? 0),
            nextRetryAt: row.date("nextRetryAt") ?? Date(),
            lastError: row.text("lastError"),
            remoteItemID: row.text("remoteItemID"),
            remoteWebURL: row.text("remoteWebURL"),
            updatedAt: row.date("updatedAt") ?? Date()
        )
    }
}
