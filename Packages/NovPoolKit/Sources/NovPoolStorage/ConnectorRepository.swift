import Foundation

/// `connectors` 表读写。敏感凭据不落库，仅保存 `keychainAccountRef` 与安全作用域书签。
public struct ConnectorRepository: Sendable {
    private let database: NovPoolDatabase

    public init(database: NovPoolDatabase) {
        self.database = database
    }

    private static let columns =
        "id, name, connectorType, keychainAccountRef, bookmarkData, configJSON, isEnabled, createdAt"

    public func upsert(_ record: ConnectorRecord) async throws {
        try await database.execute(
            """
            INSERT INTO connectors (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                connectorType = excluded.connectorType,
                keychainAccountRef = excluded.keychainAccountRef,
                bookmarkData = excluded.bookmarkData,
                configJSON = excluded.configJSON,
                isEnabled = excluded.isEnabled
            """,
            [
                .text(record.id),
                .text(record.name),
                .text(record.connectorType),
                record.keychainAccountRef.map { SQLValue.text($0) } ?? .null,
                record.bookmarkData.map { SQLValue.blob($0) } ?? .null,
                .text(record.configJSON),
                .integer(record.isEnabled ? 1 : 0),
                .date(record.createdAt),
            ]
        )
    }

    public func list() async throws -> [ConnectorRecord] {
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM connectors ORDER BY createdAt"
        )
        return rows.compactMap(Self.decode)
    }

    public func fetch(id: String) async throws -> ConnectorRecord? {
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM connectors WHERE id = ?",
            [.text(id)]
        )
        return rows.first.flatMap(Self.decode)
    }

    public func setEnabled(_ isEnabled: Bool, id: String) async throws {
        try await database.execute(
            "UPDATE connectors SET isEnabled = ? WHERE id = ?",
            [.integer(isEnabled ? 1 : 0), .text(id)]
        )
    }

    public func delete(id: String) async throws {
        try await database.execute("DELETE FROM connectors WHERE id = ?", [.text(id)])
    }

    static func decode(_ row: SQLRow) -> ConnectorRecord? {
        guard let id = row.text("id"),
              let name = row.text("name"),
              let connectorType = row.text("connectorType") else { return nil }
        return ConnectorRecord(
            id: id,
            name: name,
            connectorType: connectorType,
            keychainAccountRef: row.text("keychainAccountRef"),
            bookmarkData: row.blob("bookmarkData"),
            configJSON: row.text("configJSON") ?? "{}",
            isEnabled: (row.int("isEnabled") ?? 1) != 0,
            createdAt: row.date("createdAt") ?? Date()
        )
    }
}
