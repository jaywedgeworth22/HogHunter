import Foundation
import SQLite3

/// Rolling 24-hour samples of the top processes.  History only covers time
/// Hog Hunter itself has been running.
final class HistoryStore {
    private var db: OpaquePointer?
    private let lock = NSLock()

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HogHunter", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            db = nil
            return
        }
        exec("""
        CREATE TABLE IF NOT EXISTS samples (
          ts INTEGER NOT NULL,
          pid INTEGER NOT NULL,
          name TEXT NOT NULL,
          bundle TEXT,
          cpu REAL NOT NULL,
          mem INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
        """)
        prune()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func record(_ processes: [Sampler.LiveProcess], at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(
            db,
            "INSERT INTO samples(ts,pid,name,bundle,cpu,mem) VALUES(?,?,?,?,?,?)",
            -1,
            &stmt,
            nil
        )
        defer { sqlite3_finalize(stmt) }
        let ts = Int64(date.timeIntervalSince1970)
        for proc in processes.prefix(25) {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, ts)
            sqlite3_bind_int(stmt, 2, proc.pid)
            sqlite3_bind_text(stmt, 3, proc.name, -1, SQLITE_TRANSIENT)
            if let bundle = proc.bundleId {
                sqlite3_bind_text(stmt, 4, bundle, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, proc.cpuPercent)
            sqlite3_bind_int64(stmt, 6, Int64(proc.memoryBytes))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func prune(olderThan interval: TimeInterval = 24 * 60 * 60) {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Int64(Date().timeIntervalSince1970 - interval)
        exec("DELETE FROM samples WHERE ts < \(cutoff)")
    }

    struct Aggregate {
        var key: String
        var name: String
        var bundleId: String?
        var avgCpu: Double
        var avgMem: Double
        var maxMem: UInt64
        var samples: Int
    }

    func aggregates(lookback: TimeInterval, groupByApp: Bool) -> [Aggregate] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let cutoff = Int64(Date().timeIntervalSince1970 - lookback)
        let groupExpr = groupByApp
            ? "COALESCE(bundle, name)"
            : "name || ':' || pid"
        let sql = """
        SELECT \(groupExpr) AS k,
               MIN(name) AS name,
               bundle,
               AVG(cpu) AS avg_cpu,
               AVG(mem) AS avg_mem,
               MAX(mem) AS max_mem,
               COUNT(*) AS n
        FROM samples
        WHERE ts >= \(cutoff)
        GROUP BY k
        ORDER BY avg_cpu DESC
        LIMIT 30
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Aggregate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let bundle: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            out.append(
                Aggregate(
                    key: key,
                    name: name,
                    bundleId: bundle,
                    avgCpu: sqlite3_column_double(stmt, 3),
                    avgMem: sqlite3_column_double(stmt, 4),
                    maxMem: UInt64(sqlite3_column_int64(stmt, 5)),
                    samples: Int(sqlite3_column_int(stmt, 6))
                )
            )
        }
        return out
    }

    func oldestSampleAge() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(ts) FROM samples", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let min = sqlite3_column_int64(stmt, 0)
        guard min > 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(min)
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
