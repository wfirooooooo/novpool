import Foundation
import NovPoolCore
import SQLite3

/// SQLite 绑定值。
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue {
    public static func date(_ value: Date) -> SQLValue { .text(SQLiteDate.string(from: value)) }
}

/// 一行查询结果。列名到值的有序映射。
public struct SQLRow: Sendable {
    private let values: [String: SQLValue]

    init(values: [String: SQLValue]) {
        self.values = values
    }

    public subscript(column: String) -> SQLValue? { values[column] }

    public func text(_ column: String) -> String? {
        if case .text(let value) = values[column] { return value }
        return nil
    }

    public func int(_ column: String) -> Int64? {
        switch values[column] {
        case .integer(let value): value
        case .real(let value): Int64(value)
        default: nil
        }
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    public func blob(_ column: String) -> Data? {
        if case .blob(let value) = values[column] { return value }
        return nil
    }

    public func date(_ column: String) -> Date? {
        guard let raw = text(column) else { return nil }
        return SQLiteDate.date(from: raw)
    }
}

/// 单连接 SQLite 封装（actor 串行化访问）。
///
/// 说明：产品白皮书规划使用 `GRDB.swift` 的 `DatabasePool`；当前开发环境离线，
/// 无法拉取 SPM 依赖，因此这里直接封装系统 `libsqlite3`（WAL + FTS5 已在内核层验证），
/// 保持与白皮书 §4.2 完全一致的 Schema，后续可在不改动上层调用点的前提下替换为 GRDB。
public actor NovPoolDatabase {
    /// sqlite3 连接句柄的持有者。
    ///
    /// 用一个普通类包一层，是为了让 `deinit` 能在 actor 之外安全关闭连接
    /// （Swift 6 的 `nonisolated deinit` 不允许触碰 actor 状态里的非 Sendable 指针）。
    private final class Connection: @unchecked Sendable {
        var handle: OpaquePointer?

        deinit {
            if let handle { sqlite3_close_v2(handle) }
        }
    }

    private let connection: Connection
    public let path: String

    private var handle: OpaquePointer? { connection.handle }

    /// - Parameter createParentDirectory: 是否自动创建数据库文件的父目录（默认开启）。
    ///   SQLite 自己不会创建父目录，缺失时直接报 CANTOPEN；首次启动最容易踩这个坑。
    public init(path: String, createParentDirectory: Bool = true) throws {
        self.path = path
        self.connection = Connection()
        if createParentDirectory, path != ":memory:" {
            let parent = URL(filePath: path).deletingLastPathComponent()
            if parent.path(percentEncoded: false) != "/" {
                try NovPoolPaths.ensureDirectory(at: parent)
            }
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            throw NovPoolError.database("open failed (\(code)): \(message)")
        }
        self.connection.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
        try Self.executeRaw(handle, "PRAGMA journal_mode = WAL")
        try Self.executeRaw(handle, "PRAGMA foreign_keys = ON")
        try Self.executeRaw(handle, "PRAGMA synchronous = NORMAL")
    }

    /// 内存库，仅用于单元测试。
    public init(inMemory: Bool) throws {
        try self.init(path: inMemory ? ":memory:" : ":memory:?cache=private")
    }

    public func close() {
        if let handle {
            sqlite3_close_v2(handle)
            connection.handle = nil
        }
    }

    // MARK: - 执行

    @discardableResult
    public func execute(_ sql: String, _ arguments: [SQLValue] = []) throws -> Int {
        let connection = try requireConnection()
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw lastError(code)
        }
        return Int(sqlite3_changes(connection))
    }

    public func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var rows: [SQLRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw lastError(code) }
            var values: [String: SQLValue] = [:]
            values.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    values[names[index]] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    values[names[index]] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let pointer = sqlite3_column_text(statement, column) {
                        values[names[index]] = .text(String(cString: pointer))
                    }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    if let pointer = sqlite3_column_blob(statement, column), length > 0 {
                        values[names[index]] = .blob(Data(bytes: pointer, count: length))
                    } else {
                        values[names[index]] = .blob(Data())
                    }
                default:
                    values[names[index]] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    /// 在一个事务里批量执行语句（任一步失败即整体回滚）。
    ///
    /// actor 隔离保证事务期间不会有其他任务插入执行；因此这里用批量语句而不是
    /// 闭包式事务——闭包在 `nonisolated` 上下文里无法安全访问数据库连接。
    public func executeBatch(
        _ statements: [String],
        _ parameterized: [(String, [SQLValue])] = []
    ) throws {
        let connection = try requireConnection()
        try Self.executeRaw(connection, "BEGIN IMMEDIATE")
        do {
            for statement in statements {
                try Self.executeRaw(connection, statement)
            }
            for (sql, arguments) in parameterized {
                try execute(sql, arguments)
            }
            try Self.executeRaw(connection, "COMMIT")
        } catch {
            try? Self.executeRaw(connection, "ROLLBACK")
            throw error
        }
    }

    public var lastInsertedRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    public func scalarInt(_ sql: String, _ arguments: [SQLValue] = []) throws -> Int64? {
        try query(sql, arguments).first?.int("value")
    }

    // MARK: - 内部

    private func requireConnection() throws -> OpaquePointer {
        guard let handle else { throw NovPoolError.database("数据库连接已关闭") }
        return handle
    }

    private func prepare(_ sql: String, _ arguments: [SQLValue]) throws -> OpaquePointer {
        let connection = try requireConnection()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw lastError(code)
        }
        do {
            try Self.bind(statement, arguments)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private static func bind(_ statement: OpaquePointer, _ arguments: [SQLValue]) throws {
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let raw):
                code = sqlite3_bind_int64(statement, index, raw)
            case .real(let raw):
                code = sqlite3_bind_double(statement, index, raw)
            case .text(let raw):
                code = sqlite3_bind_text(statement, index, raw, -1, sqliteTransient)
            case .blob(let raw):
                if raw.isEmpty {
                    code = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    code = raw.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(raw.count), sqliteTransient)
                    }
                }
            }
            guard code == SQLITE_OK else {
                throw NovPoolError.database("bind failed at index \(index) (\(code))")
            }
        }
    }

    private static func executeRaw(_ handle: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw NovPoolError.database("\(sql): \(message)")
        }
    }

    private func lastError(_ code: Int32) -> NovPoolError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .database("sqlite code \(code): \(message)")
    }
}

/// SQLite 没有 `SQLITE_TRANSIENT` 的 Swift 常量，需自行还原（-1 指针）。
private nonisolated(unsafe) let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 日期以 ISO8601 文本存储，与白皮书 `.datetime` 列语义一致且跨语言可读。
public enum SQLiteDate {
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
