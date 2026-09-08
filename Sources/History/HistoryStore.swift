import Darwin
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A rolling 24 hours of the heaviest processes, one row per recorded tick.
///
/// Schema v2 keeps a `ticks` table beside `samples` so an average can be taken
/// over the window's whole length rather than over the rows that happen to
/// exist: a process seen in 3 of 120 ticks should read as a small average, not
/// as its own busy moments.  The database URL is always explicit so tests and
/// command-line checks never touch the installed app's file.
///
/// `@unchecked Sendable` is honest here: every entry point takes the same lock,
/// and the store is only called from the sampling queue.
final class HistoryStore: @unchecked Sendable {
    struct Aggregate {
        var key: String
        var name: String
        var bundleId: String?
        /// Average over every tick in the window, not only the ticks the
        /// process appeared in.
        var avgCpu: Double
        var avgMemoryBytes: Double
        var peakMemoryBytes: UInt64
        var peakCpu: Double
        var sampleCount: Int
        var windowTicks: Int

        /// Fraction of the window's ticks in which this key appeared, 0-1.
        var presence: Double {
            guard windowTicks > 0 else { return 0 }
            return min(1, Double(sampleCount) / Double(windowTicks))
        }
    }

    struct Coverage {
        var tickCount: Int
        var sampledSeconds: TimeInterval
        var firstTimestamp: Date?
    }

    /// Why a row was kept, as a bit field.
    enum Reason {
        static let cpu = 1
        static let memory = 2
    }

    private struct MemoKey: Hashable {
        var lookback: TimeInterval
        var groupByApp: Bool
        var sort: HogSort
        var lastTs: Int64
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private var memo: [MemoKey: [Aggregate]] = [:]
    private var lastRecordedTs: Int64 = 0
    private var lastPrune = Date.distantPast

    /// The most recent SQLite failure, for the panel to show.
    private(set) var lastError: String?

    static var defaultURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HogHunter", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("history.sqlite")
    }

    init(url: URL) {
        open(path: url.path)
    }

    /// An in-memory database.  Used by tests and by any check that must not
    /// touch the installed app's history.
    init(inMemory: Bool) {
        open(path: inMemory ? ":memory:" : Self.defaultURL.path)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            lastError = "Could not open the history database."
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;", label: "journal mode")
        exec("PRAGMA synchronous=NORMAL;", label: "synchronous")
        migrate()
        prune()
    }

    // MARK: - Schema

    private func migrate() {
        guard db != nil else { return }
        let version = scalarInt("PRAGMA user_version")
        if version < 2 {
            // v1 stored raw mach ticks read as nanoseconds, so every CPU value
            // in it was 41.7x too small.  There is nothing worth migrating.
            exec("DROP TABLE IF EXISTS samples;", label: "drop v1 samples")
            exec("DROP INDEX IF EXISTS samples_ts;", label: "drop v1 index")
        }
        exec(
            """
            CREATE TABLE IF NOT EXISTS ticks (ts INTEGER PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS samples (
              ts INTEGER NOT NULL,
              pid INTEGER NOT NULL,
              start INTEGER NOT NULL,
              key TEXT NOT NULL,
              group_key TEXT NOT NULL,
              name TEXT NOT NULL,
              bundle TEXT,
              cpu REAL NOT NULL,
              mem INTEGER NOT NULL,
              reason INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
            """,
            label: "create v2 schema"
        )
        exec("PRAGMA user_version=2;", label: "set user version")
    }

    // MARK: - Recording

    /// Records one tick: the union of the top 25 by CPU and the top 25 by
    /// footprint.  `reason` says which list each row came from.
    func record(
        samples: [ProcessSample],
        groupKey: (ProcessSample) -> String,
        bundleId: (ProcessSample) -> String?,
        coreCount: Int,
        at date: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let ceiling = CpuMath.ceiling(coreCount: coreCount)
        let byCpu = samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(25)
        let byMemory = samples.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(25)
        var reasons: [ProcessKey: Int] = [:]
        var chosen: [ProcessKey: ProcessSample] = [:]
        for sample in byCpu {
            reasons[sample.key, default: 0] |= Reason.cpu
            chosen[sample.key] = sample
        }
        for sample in byMemory {
            reasons[sample.key, default: 0] |= Reason.memory
            chosen[sample.key] = sample
        }
        guard !chosen.isEmpty else { return }

        let ts = Int64(date.timeIntervalSince1970)
        guard check(sqlite3_exec(db, "BEGIN", nil, nil, nil), "begin") else { return }

        var tickStatement: OpaquePointer?
        if check(sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO ticks(ts) VALUES(?)", -1, &tickStatement, nil), "prepare tick") {
            sqlite3_bind_int64(tickStatement, 1, ts)
            _ = check(sqlite3_step(tickStatement), "insert tick", expected: SQLITE_DONE)
        }
        sqlite3_finalize(tickStatement)

        var statement: OpaquePointer?
        let sql = """
        INSERT INTO samples(ts,pid,start,key,group_key,name,bundle,cpu,mem,reason)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        """
        if check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare sample") {
            for (identity, sample) in chosen {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, ts)
                sqlite3_bind_int(statement, 2, identity.pid)
                sqlite3_bind_int64(statement, 3, Int64(bitPattern: identity.startTime))
                sqlite3_bind_text(statement, 4, "\(identity.pid)-\(identity.startTime)", -1, sqliteTransient)
                sqlite3_bind_text(statement, 5, groupKey(sample), -1, sqliteTransient)
                sqlite3_bind_text(statement, 6, sample.name, -1, sqliteTransient)
                if let bundle = bundleId(sample) {
                    sqlite3_bind_text(statement, 7, bundle, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, 7)
                }
                sqlite3_bind_double(statement, 8, min(max(0, sample.cpuPercent), ceiling))
                sqlite3_bind_int64(statement, 9, Int64(bitPattern: sample.footprintBytes))
                sqlite3_bind_int(statement, 10, Int32(reasons[identity] ?? 0))
                _ = check(sqlite3_step(statement), "insert sample", expected: SQLITE_DONE)
            }
        }
        sqlite3_finalize(statement)
        _ = check(sqlite3_exec(db, "COMMIT", nil, nil, nil), "commit")
        lastRecordedTs = ts
    }

    // MARK: - Reading

    /// Per-timestamp sums first, then an average over the window's tick count.
    /// Memoized on `lastRecordedTs`, so the panel may ask on every tick.
    func aggregates(lookback: TimeInterval, groupByApp: Bool, sort: HogSort) -> [Aggregate] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let memoKey = MemoKey(lookback: lookback, groupByApp: groupByApp, sort: sort, lastTs: lastRecordedTs)
        if let cached = memo[memoKey] { return cached }

        let cutoff = Int64(Date().timeIntervalSince1970 - lookback)
        let column = groupByApp ? "group_key" : "key"
        let order = sort == .cpu ? 4 : 5
        let sql = """
        WITH win AS (SELECT COUNT(*) AS n FROM ticks WHERE ts >= ?1),
        per_ts AS (
          SELECT ts, \(column) AS k, SUM(cpu) AS cpu, SUM(mem) AS mem,
                 MIN(name) AS name, MIN(bundle) AS bundle
          FROM samples WHERE ts >= ?1 GROUP BY ts, k
        )
        SELECT k, MIN(name), MIN(bundle),
               SUM(cpu) * 1.0 / win.n, SUM(mem) * 1.0 / win.n,
               MAX(mem), MAX(cpu), COUNT(*), win.n
        FROM per_ts, win
        GROUP BY k
        ORDER BY \(order) DESC
        LIMIT 40
        """

        var statement: OpaquePointer?
        guard check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare aggregates") else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)

        var out: [Aggregate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let windowTicks = Int(sqlite3_column_int(statement, 8))
            guard windowTicks > 0 else { continue }
            out.append(
                Aggregate(
                    key: text(statement, 0) ?? "",
                    name: text(statement, 1) ?? "",
                    bundleId: text(statement, 2),
                    avgCpu: sqlite3_column_double(statement, 3),
                    avgMemoryBytes: sqlite3_column_double(statement, 4),
                    peakMemoryBytes: UInt64(bitPattern: sqlite3_column_int64(statement, 5)),
                    peakCpu: sqlite3_column_double(statement, 6),
                    sampleCount: Int(sqlite3_column_int(statement, 7)),
                    windowTicks: windowTicks
                )
            )
        }
        memo = [memoKey: out]
        return out
    }

    /// How much of the window Hog Hunter was actually running for.
    func coverage(lookback: TimeInterval, secondsPerTick: TimeInterval) -> Coverage {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil) }
        let cutoff = Int64(Date().timeIntervalSince1970 - lookback)
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*), MIN(ts) FROM ticks WHERE ts >= ?"
        guard check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "prepare coverage") else {
            sqlite3_finalize(statement)
            return Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil)
        }
        let count = Int(sqlite3_column_int(statement, 0))
        let first = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)))
        return Coverage(
            tickCount: count,
            sampledSeconds: Double(count) * secondsPerTick,
            firstTimestamp: first
        )
    }

    /// Drops everything older than the retention window.  Safe to call often;
    /// it does real work at most every 20 minutes.
    func prune(olderThan retention: TimeInterval = 24 * 60 * 60, force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if !force, now.timeIntervalSince(lastPrune) < 20 * 60 { return }
        lastPrune = now
        let cutoff = Int64(now.timeIntervalSince1970 - retention)
        exec("DELETE FROM samples WHERE ts < \(cutoff); DELETE FROM ticks WHERE ts < \(cutoff);", label: "prune")
        memo.removeAll()
    }

    // MARK: - SQLite plumbing

    @discardableResult
    private func exec(_ sql: String, label: String) -> Bool {
        guard let db else { return false }
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &message)
        if code != SQLITE_OK {
            lastError = "History \(label) failed (\(code))."
            if let message { sqlite3_free(message) }
            return false
        }
        if let message { sqlite3_free(message) }
        return true
    }

    private func check(_ code: Int32, _ label: String, expected: Int32 = SQLITE_OK) -> Bool {
        if code == expected || code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW { return true }
        lastError = "History \(label) failed (\(code))."
        return false
    }

    private func scalarInt(_ sql: String) -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}
