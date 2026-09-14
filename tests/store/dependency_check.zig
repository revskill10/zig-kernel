//! Actual-file SQLite 3.53.4 dependency gate. Dual main/test root.
//! Probe CLI: store-dependency-probe <seed|reopen> <owned-file-path>
//! No in-memory URI, no user workload exec, no contracts.Store wiring.

const std = @import("std");
const builtin = @import("builtin");
const sqlite_c = @import("sqlite_c");

pub const Mode = enum { seed, reopen };

pub const CliError = error{
    InvalidArgs,
    WrongMode,
    VersionMismatch,
    MemoryDatabaseRejected,
};

pub const principal_blob = [_]u8{ 0x00, 0xFF, 0x42, 0x00 };
pub const nul_text = [_]u8{ 'A', 0x00, 'B' };
pub const non_utf8 = [_]u8{ 0xFF, 0xFE, 0x80 };

pub fn parseMode(s: []const u8) ?Mode {
    if (std.mem.eql(u8, s, "seed")) return .seed;
    if (std.mem.eql(u8, s, "reopen")) return .reopen;
    return null;
}

pub fn parseCli(args: []const []const u8) CliError!struct { mode: Mode, path: []const u8 } {
    if (args.len != 3) return error.InvalidArgs;
    const mode = parseMode(args[1]) orelse return error.WrongMode;
    if (sqlite_c.isRejectedPath(args[2])) {
        if (args[2].len == 0) return error.InvalidArgs;
        return error.MemoryDatabaseRejected;
    }
    return .{ .mode = mode, .path = args[2] };
}

const Report = struct {
    journal: [16]u8 = undefined,
    journal_len: usize = 0,
    synchronous: [8]u8 = undefined,
    synchronous_len: usize = 0,
    foreign_keys: [8]u8 = undefined,
    foreign_keys_len: usize = 0,
    integrity: [8]u8 = undefined,
    integrity_len: usize = 0,
    count: [8]u8 = undefined,
    count_len: usize = 0,
};

fn copyField(dest: []u8, src: []const u8) usize {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

fn applyObservedSettings(conn: *sqlite_c.Conn, report: *Report) sqlite_c.Error!void {
    var buf: [32]u8 = undefined;
    const journal = try conn.queryText("PRAGMA journal_mode=WAL", &buf);
    if (!std.ascii.eqlIgnoreCase(journal, "wal")) return error.Sql;
    report.journal_len = copyField(&report.journal, journal);

    try conn.exec("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");

    const syn = try conn.queryText("PRAGMA synchronous", &buf);
    if (!std.mem.eql(u8, syn, "2")) return error.Sql;
    report.synchronous_len = copyField(&report.synchronous, syn);

    const fk = try conn.queryText("PRAGMA foreign_keys", &buf);
    if (!std.mem.eql(u8, fk, "1")) return error.Sql;
    report.foreign_keys_len = copyField(&report.foreign_keys, fk);
}

fn seed(conn: *sqlite_c.Conn) sqlite_c.Error!void {
    try conn.exec(
        \\CREATE TABLE probe(
        \\  k TEXT PRIMARY KEY,
        \\  v BLOB NOT NULL,
        \\  t TEXT
        \\);
        \\CREATE TABLE parent(id TEXT PRIMARY KEY);
        \\CREATE TABLE child(
        \\  id TEXT PRIMARY KEY,
        \\  parent_id TEXT NOT NULL REFERENCES parent(id)
        \\);
        \\CREATE TABLE empty_nn(
        \\  k TEXT PRIMARY KEY,
        \\  blob_nn BLOB NOT NULL,
        \\  text_nn TEXT NOT NULL
        \\);
        \\CREATE TABLE nullable_t(x TEXT);
        \\INSERT INTO parent VALUES('p1');
    );

    try conn.exec("BEGIN IMMEDIATE;");
    {
        var blob = principal_blob;
        var text = nul_text;
        var stmt = try conn.prepare("INSERT INTO probe(k, v, t) VALUES(?1, ?2, ?3)");
        defer stmt.finalizeQuiet();
        try stmt.bindTextTransient(1, "principal-key");
        try stmt.bindBlobTransient(2, &blob);
        try stmt.bindTextTransient(3, &text);
        @memset(&blob, 0xAA);
        @memset(&text, 0xBB);
        try stmt.expectDone();
    }
    try conn.exec("COMMIT;");

    try conn.exec("BEGIN IMMEDIATE;");
    {
        var extra = non_utf8;
        var stmt = try conn.prepare("INSERT INTO probe(k, v) VALUES(?1, ?2)");
        defer stmt.finalizeQuiet();
        try stmt.bindTextTransient(1, "rolled-back");
        try stmt.bindBlobTransient(2, &extra);
        @memset(&extra, 0x11);
        try stmt.expectDone();
    }
    try conn.exec("ROLLBACK;");

    {
        var extra = non_utf8;
        var stmt = try conn.prepare("INSERT INTO probe(k, v) VALUES(?1, ?2)");
        defer stmt.finalizeQuiet();
        try stmt.bindTextTransient(1, "nonutf8");
        try stmt.bindBlobTransient(2, &extra);
        @memset(&extra, 0x22);
        try stmt.expectDone();
    }

    {
        var stmt = try conn.prepare("INSERT INTO empty_nn(k, blob_nn, text_nn) VALUES(?1, ?2, ?3)");
        defer stmt.finalizeQuiet();
        try stmt.bindTextTransient(1, "empty");
        try stmt.bindBlobTransient(2, &[_]u8{});
        try stmt.bindTextTransient(3, "");
        try stmt.expectDone();
    }

    try conn.exec("INSERT INTO nullable_t VALUES(NULL)");

    try conn.execExpect("INSERT INTO child VALUES('c1', 'missing')", sqlite_c.SQLITE_CONSTRAINT);
    try conn.exec("INSERT INTO child VALUES('c1', 'p1')");
}

fn verifyEmptyNotNull(conn: *sqlite_c.Conn) sqlite_c.Error!void {
    {
        var stmt = try conn.prepare("SELECT typeof(blob_nn), typeof(text_nn), length(blob_nn), length(text_nn) FROM empty_nn WHERE k='empty'");
        defer stmt.finalizeQuiet();
        try stmt.expectRow();
        var type_blob_buf: [8]u8 = undefined;
        var type_text_buf: [8]u8 = undefined;
        var len_blob_buf: [8]u8 = undefined;
        var len_text_buf: [8]u8 = undefined;
        const type_blob = try stmt.columnTextCopy(0, &type_blob_buf);
        const type_text = try stmt.columnTextCopy(1, &type_text_buf);
        const len_blob = try stmt.columnTextCopy(2, &len_blob_buf);
        const len_text = try stmt.columnTextCopy(3, &len_text_buf);
        if (!std.mem.eql(u8, type_blob, "blob")) return error.Sql;
        if (!std.mem.eql(u8, type_text, "text")) return error.Sql;
        if (!std.mem.eql(u8, len_blob, "0")) return error.Sql;
        if (!std.mem.eql(u8, len_text, "0")) return error.Sql;
        try stmt.expectDone();
    }
    {
        var stmt = try conn.prepare("SELECT blob_nn, text_nn FROM empty_nn WHERE k='empty'");
        defer stmt.finalizeQuiet();
        try stmt.expectRow();
        if (stmt.columnType(0) != sqlite_c.SQLITE_BLOB) return error.Sql;
        if (stmt.columnType(1) != sqlite_c.SQLITE_TEXT) return error.Sql;
        var blob_buf: [8]u8 = undefined;
        var text_buf: [8]u8 = undefined;
        const blob = try stmt.columnBlobCopy(0, &blob_buf);
        const text = try stmt.columnTextCopy(1, &text_buf);
        if (blob.len != 0) return error.Sql;
        if (text.len != 0) return error.Sql;
        try stmt.expectDone();
    }
}

fn verifyPersisted(conn: *sqlite_c.Conn, report: *Report, expect_nonutf8: bool) sqlite_c.Error!void {
    var hex_buf: [16]u8 = undefined;
    const hex = try conn.queryText("SELECT hex(v) FROM probe WHERE k='principal-key'", &hex_buf);
    if (!std.mem.eql(u8, hex, "00FF4200")) return error.Sql;

    {
        var stmt = try conn.prepare("SELECT v, t FROM probe WHERE k='principal-key'");
        defer stmt.finalizeQuiet();
        try stmt.expectRow();
        var blob_buf: [8]u8 = undefined;
        var text_buf: [8]u8 = undefined;
        const blob = try stmt.columnBlobCopy(0, &blob_buf);
        const text = try stmt.columnTextCopy(1, &text_buf);
        if (!std.mem.eql(u8, blob, &principal_blob)) return error.Sql;
        if (!std.mem.eql(u8, text, &nul_text)) return error.Sql;
        try stmt.expectDone();
    }

    if (expect_nonutf8) {
        var stmt = try conn.prepare("SELECT v FROM probe WHERE k='nonutf8'");
        defer stmt.finalizeQuiet();
        try stmt.expectRow();
        var blob_buf: [8]u8 = undefined;
        const blob = try stmt.columnBlobCopy(0, &blob_buf);
        if (!std.mem.eql(u8, blob, &non_utf8)) return error.Sql;
        try stmt.expectDone();
    }

    try verifyEmptyNotNull(conn);

    var count_buf: [8]u8 = undefined;
    const count = try conn.queryText("SELECT count(*) FROM probe", &count_buf);
    const expected_count: []const u8 = if (expect_nonutf8) "2" else "1";
    if (!std.mem.eql(u8, count, expected_count)) return error.Sql;
    report.count_len = copyField(&report.count, count);

    const rolled = try conn.queryText("SELECT count(*) FROM probe WHERE k='rolled-back'", &count_buf);
    if (!std.mem.eql(u8, rolled, "0")) return error.Sql;

    const integrity = try conn.queryText("PRAGMA integrity_check", &count_buf);
    if (!std.mem.eql(u8, integrity, "ok")) return error.Sql;
    report.integrity_len = copyField(&report.integrity, integrity);
}

pub fn runMode(mode: Mode, path: []const u8) sqlite_c.Error!Report {
    try sqlite_c.requirePinnedVersion();
    if (!sqlite_c.omitLoadExtensionUsed()) return error.Sql;
    if (!sqlite_c.threadsafeSerialized()) return error.Sql;

    var conn = try sqlite_c.Conn.openFile(path, mode == .seed);
    var report = Report{};
    errdefer conn.close() catch {};

    try applyObservedSettings(&conn, &report);
    if (mode == .seed) try seed(&conn);
    try verifyPersisted(&conn, &report, true);
    try conn.close();
    return report;
}

fn formatLineWithIdentity(
    buf: []u8,
    mode: Mode,
    report: Report,
    version: []const u8,
    source_id: []const u8,
) error{EvidenceFormat}![]const u8 {
    if (version.len == 0 or source_id.len == 0) return error.EvidenceFormat;
    if (report.journal_len == 0 or report.synchronous_len == 0 or report.foreign_keys_len == 0 or
        report.integrity_len == 0 or report.count_len == 0)
        return error.EvidenceFormat;
    return std.fmt.bufPrint(buf, "sqlite_dependency_probe mode={s} version={s} source_id={s} journal={s} synchronous={s} foreign_keys={s} omit_load_extension=1 threadsafe=1 integrity={s} count={s} blob=00FF4200 passed=1\n", .{
        @tagName(mode),
        version,
        source_id,
        report.journal[0..report.journal_len],
        report.synchronous[0..report.synchronous_len],
        report.foreign_keys[0..report.foreign_keys_len],
        report.integrity[0..report.integrity_len],
        report.count[0..report.count_len],
    }) catch return error.EvidenceFormat;
}

fn formatLine(buf: []u8, mode: Mode, report: Report) error{EvidenceFormat}![]const u8 {
    return formatLineWithIdentity(buf, mode, report, sqlite_c.libversion(), sqlite_c.sourceId());
}

fn writeEvidence(io: std.Io, file: std.Io.File, bytes: []const u8) error{EvidenceWrite}!void {
    file.writeStreamingAll(io, bytes) catch return error.EvidenceWrite;
}

fn writeOut(io: std.Io, bytes: []const u8) error{EvidenceWrite}!void {
    try writeEvidence(io, std.Io.File.stdout(), bytes);
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const raw = init.minimal.args.toSlice(init.gpa) catch {
        writeErr(io, "sqlite_dependency_probe invalid-args\n");
        std.process.exit(2);
    };
    const args = init.gpa.alloc([]const u8, raw.len) catch {
        writeErr(io, "sqlite_dependency_probe invalid-args\n");
        std.process.exit(2);
    };
    for (raw, 0..) |item, i| args[i] = item;
    const parsed = parseCli(args) catch |err| switch (err) {
        error.InvalidArgs => {
            writeErr(io, "usage: store-dependency-probe <seed|reopen> <file>\n");
            std.process.exit(2);
        },
        error.WrongMode => {
            writeErr(io, "sqlite_dependency_probe wrong-mode\n");
            std.process.exit(2);
        },
        error.MemoryDatabaseRejected => {
            writeErr(io, "sqlite_dependency_probe memory-db-rejected\n");
            std.process.exit(2);
        },
        error.VersionMismatch => {
            writeErr(io, "sqlite_dependency_probe version-mismatch\n");
            std.process.exit(3);
        },
    };

    sqlite_c.checkClaimedVersion(sqlite_c.expected_version) catch {
        writeErr(io, "sqlite_dependency_probe version-mismatch\n");
        std.process.exit(3);
    };

    const report = runMode(parsed.mode, parsed.path) catch |err| switch (err) {
        error.VersionMismatch => {
            writeErr(io, "sqlite_dependency_probe version-mismatch\n");
            std.process.exit(3);
        },
        error.OpenFailed, error.InvalidPath, error.MemoryDatabaseRejected => {
            writeErr(io, "sqlite_dependency_probe open-failed\n");
            std.process.exit(4);
        },
        else => {
            writeErr(io, "sqlite_dependency_probe sql-failed\n");
            std.process.exit(5);
        },
    };

    var line_buf: [512]u8 = undefined;
    const line = formatLine(&line_buf, parsed.mode, report) catch {
        writeErr(io, "sqlite_dependency_probe evidence-format-failed\n");
        std.process.exit(6);
    };
    writeOut(io, line) catch {
        writeErr(io, "sqlite_dependency_probe evidence-write-failed\n");
        std.process.exit(6);
    };
}

const owned_name_random_bytes = 12;
const owned_name_len = std.base64.url_safe.Encoder.calcSize(owned_name_random_bytes);

const OwnedDbDir = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    name: [owned_name_len]u8,
    dir_path: []u8,
    db_path: []u8,

    fn create(allocator: std.mem.Allocator, io: std.Io) !OwnedDbDir {
        const cwd_path = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd_path);
        try requireTempOnD(cwd_path);

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, ".zig-cache/tmp");
        var parent = try cwd.openDir(io, ".zig-cache/tmp", .{});
        defer parent.close(io);

        var random_bytes: [owned_name_random_bytes]u8 = undefined;
        var name: [owned_name_len]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 64) : (attempts += 1) {
            io.random(&random_bytes);
            _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
            parent.createDir(io, &name, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            break;
        } else return error.TempDirCreateFailed;

        const dir_path = try std.Io.Dir.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &name });
        errdefer allocator.free(dir_path);
        const db_path = try std.Io.Dir.path.join(allocator, &.{ dir_path, "probe.db" });
        errdefer allocator.free(db_path);
        try requireTempOnD(db_path);
        return .{
            .allocator = allocator,
            .io = io,
            .name = name,
            .dir_path = dir_path,
            .db_path = db_path,
        };
    }

    fn cleanup(self: *OwnedDbDir) void {
        if (self.dir_path.len == 0) return;
        var rel_buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&self.name})) |rel| {
            std.Io.Dir.cwd().deleteTree(self.io, rel) catch {};
        } else |_| {}
        self.allocator.free(self.db_path);
        self.allocator.free(self.dir_path);
        self.db_path.len = 0;
        self.dir_path.len = 0;
    }
};

fn requireTempOnD(path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        if (!(path.len >= 2 and (path[0] == 'D' or path[0] == 'd') and path[1] == ':'))
            return error.TempNotOnD;
    }
}

fn filledReport() Report {
    var report = Report{};
    report.journal_len = copyField(&report.journal, "wal");
    report.synchronous_len = copyField(&report.synchronous, "2");
    report.foreign_keys_len = copyField(&report.foreign_keys, "1");
    report.integrity_len = copyField(&report.integrity, "ok");
    report.count_len = copyField(&report.count, "2");
    return report;
}

test "cli rejects wrong mode invalid args and memory db" {
    try std.testing.expect(parseMode("exec") == null);
    try std.testing.expect(parseMode("memory") == null);
    try std.testing.expectError(error.InvalidArgs, parseCli(&.{"probe"}));
    try std.testing.expectError(error.InvalidArgs, parseCli(&.{ "probe", "seed" }));
    try std.testing.expectError(error.WrongMode, parseCli(&.{ "probe", "exec", "x.db" }));
    try std.testing.expectError(error.MemoryDatabaseRejected, parseCli(&.{ "probe", "seed", ":memory:" }));
    try std.testing.expectError(error.MemoryDatabaseRejected, parseCli(&.{ "probe", "reopen", "file:x?mode=memory" }));
    try std.testing.expectError(error.VersionMismatch, sqlite_c.checkClaimedVersion("3.0.0"));
    try sqlite_c.checkClaimedVersion("3.53.4");
}

test "open rejects memory uri and empty path" {
    try std.testing.expectError(error.MemoryDatabaseRejected, sqlite_c.Conn.openFile(":memory:", true));
    try std.testing.expectError(error.MemoryDatabaseRejected, sqlite_c.Conn.openFile("file:memdb?mode=memory", true));
    try std.testing.expectError(error.InvalidPath, sqlite_c.Conn.openFile("", true));
}

test "actual file seed reopen blob text lifetimes wal full fk" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var owned = try OwnedDbDir.create(allocator, io);
    defer owned.cleanup();

    if (builtin.os.tag == .windows) {
        try std.testing.expect(owned.db_path.len >= 2 and (owned.db_path[0] == 'D' or owned.db_path[0] == 'd') and owned.db_path[1] == ':');
    }

    const seed_report = try runMode(.seed, owned.db_path);
    try std.testing.expectEqualStrings("wal", seed_report.journal[0..seed_report.journal_len]);
    try std.testing.expectEqualStrings("2", seed_report.synchronous[0..seed_report.synchronous_len]);
    try std.testing.expectEqualStrings("1", seed_report.foreign_keys[0..seed_report.foreign_keys_len]);
    try std.testing.expectEqualStrings("ok", seed_report.integrity[0..seed_report.integrity_len]);

    const reopen_report = try runMode(.reopen, owned.db_path);
    try std.testing.expectEqualStrings("wal", reopen_report.journal[0..reopen_report.journal_len]);
    try std.testing.expectEqualStrings("2", reopen_report.synchronous[0..reopen_report.synchronous_len]);
    try std.testing.expectEqualStrings("1", reopen_report.foreign_keys[0..reopen_report.foreign_keys_len]);
    try std.testing.expectEqualStrings("ok", reopen_report.integrity[0..reopen_report.integrity_len]);
    try std.testing.expect(sqlite_c.omitLoadExtensionUsed());
    try std.testing.expect(sqlite_c.threadsafeSerialized());
    try std.testing.expectEqualStrings("3.53.4", sqlite_c.libversion());
    try std.testing.expectEqualStrings(sqlite_c.expected_source_id, sqlite_c.sourceId());

    var line_buf: [512]u8 = undefined;
    const line = try formatLine(&line_buf, .reopen, reopen_report);
    try std.testing.expect(std.mem.indexOf(u8, line, "version=3.53.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "source_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "journal=wal") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "passed=1") != null);
}

test "busy close retains live handle then finalize retry" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var owned = try OwnedDbDir.create(allocator, io);
    defer owned.cleanup();

    var conn = try sqlite_c.Conn.openFile(owned.db_path, true);
    var conn_open = true;
    defer if (conn_open) conn.close() catch {};
    const handle = conn.db;
    var stmt = try conn.prepare("SELECT 1");
    var stmt_live = true;
    defer if (stmt_live) stmt.finalizeQuiet();
    try std.testing.expectError(error.CloseFailed, conn.close());
    try std.testing.expect(conn.db == handle);
    try std.testing.expect(sqlite_c.sqlite3_db_handle(stmt.stmt) == handle);
    try stmt.expectRow();
    try stmt.finalize();
    stmt_live = false;
    try conn.exec("CREATE TABLE after_busy(k TEXT PRIMARY KEY);");
    try conn.close();
    conn_open = false;
}

test "empty blob and text bind as typed empty not sql null through reopen" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var owned = try OwnedDbDir.create(allocator, io);
    defer owned.cleanup();

    {
        var conn = try sqlite_c.Conn.openFile(owned.db_path, true);
        defer conn.close() catch {};
        try conn.exec(
            \\CREATE TABLE empty_nn(
            \\  k TEXT PRIMARY KEY,
            \\  blob_nn BLOB NOT NULL,
            \\  text_nn TEXT NOT NULL
            \\);
        );
        var stmt = try conn.prepare("INSERT INTO empty_nn(k, blob_nn, text_nn) VALUES(?1, ?2, ?3)");
        defer stmt.finalizeQuiet();
        try stmt.bindTextTransient(1, "empty");
        try stmt.bindBlobTransient(2, &[_]u8{});
        try stmt.bindTextTransient(3, "");
        try stmt.expectDone();
        try verifyEmptyNotNull(&conn);
    }

    {
        var conn = try sqlite_c.Conn.openFile(owned.db_path, false);
        defer conn.close() catch {};
        try verifyEmptyNotNull(&conn);
    }
}

test "sql null empty typed value and simulated conversion failure" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var owned = try OwnedDbDir.create(allocator, io);
    defer owned.cleanup();

    var conn = try sqlite_c.Conn.openFile(owned.db_path, true);
    defer conn.close() catch {};
    try conn.exec("CREATE TABLE nullable_t(x TEXT); INSERT INTO nullable_t VALUES(NULL); INSERT INTO nullable_t VALUES('');");

    {
        var stmt = try conn.prepare("SELECT x FROM nullable_t WHERE x IS NULL");
        defer stmt.finalizeQuiet();
        try stmt.expectRow();
        try std.testing.expectEqual(sqlite_c.SQLITE_NULL, stmt.columnType(0));
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.SqlNull, stmt.columnTextCopy(0, &buf));
        try std.testing.expectError(error.SqlNull, stmt.columnBlobCopy(0, &buf));
    }
    {
        var stmt = try conn.prepare("SELECT x FROM nullable_t WHERE typeof(x)='text'");
        defer stmt.finalizeQuiet();
        try stmt.expectRow();
        try std.testing.expectEqual(sqlite_c.SQLITE_TEXT, stmt.columnType(0));
        var buf: [8]u8 = undefined;
        const text = try stmt.columnTextCopy(0, &buf);
        try std.testing.expectEqual(@as(usize, 0), text.len);
    }

    // Simulated injection of the documented OOM-looks-like-NULL ambiguity.
    // This is not a live sqlite3_config malloc hook and does not force OOM
    // by unbounded allocation. SQLITE_ROW is the live status sqlite3_step
    // leaves in errcode after a successful row; it is not conversion failure.
    try std.testing.expectError(error.ConversionFailed, sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_NOMEM,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_OK,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_NULL,
    }));
    try std.testing.expectError(error.ConversionFailed, sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_OK,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_NOMEM,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_NULL,
    }));
    try std.testing.expectError(error.ConversionFailed, sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_NOMEM,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_ROW,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_NULL,
    }));
    try std.testing.expectError(error.ConversionFailed, sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_ERROR,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_OK,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_BLOB,
    }));
    try std.testing.expectError(error.SqlNull, sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_OK,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_OK,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_NULL,
    }));
    try std.testing.expectError(error.SqlNull, sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_ROW,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_ROW,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_NULL,
    }));
    try std.testing.expectEqual(@as(usize, 0), try sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_OK,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_OK,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_BLOB,
    }));
    try std.testing.expectEqual(@as(usize, 0), try sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_ROW,
        .pointer_null = true,
        .errcode_after_bytes = sqlite_c.SQLITE_ROW,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_BLOB,
    }));
    try std.testing.expectEqual(@as(usize, 0), try sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_OK,
        .pointer_null = false,
        .errcode_after_bytes = sqlite_c.SQLITE_OK,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_TEXT,
    }));
    try std.testing.expectEqual(@as(usize, 0), try sqlite_c.interpretColumnCopy(.{
        .errcode_after_pointer = sqlite_c.SQLITE_OK,
        .pointer_null = false,
        .errcode_after_bytes = sqlite_c.SQLITE_ROW,
        .nbytes = 0,
        .col_type = sqlite_c.SQLITE_TEXT,
    }));
}

test "owned fixtures do not share paths or delete unrelated sentinel" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    var sentinel_owner = try OwnedDbDir.create(allocator, io);
    defer sentinel_owner.cleanup();
    var sentinel_rel_buf: [80]u8 = undefined;
    const sentinel_rel = try std.fmt.bufPrint(&sentinel_rel_buf, ".zig-cache/tmp/{s}/sentinel", .{&sentinel_owner.name});
    try cwd.writeFile(io, .{ .sub_path = sentinel_rel, .data = "SENTINEL-BYTES" });

    var a = try OwnedDbDir.create(allocator, io);
    defer a.cleanup();
    var b = try OwnedDbDir.create(allocator, io);
    defer b.cleanup();

    try std.testing.expect(!std.mem.eql(u8, a.db_path, b.db_path));
    try std.testing.expect(!std.mem.eql(u8, a.dir_path, b.dir_path));
    try std.testing.expect(!std.mem.eql(u8, a.dir_path, sentinel_owner.dir_path));
    try std.testing.expect(!std.mem.eql(u8, b.dir_path, sentinel_owner.dir_path));
    try std.testing.expect(std.mem.indexOf(u8, a.db_path, "store-dependency-check.db") == null);
    try std.testing.expect(std.mem.indexOf(u8, b.db_path, "store-dependency-check.db") == null);
    try std.testing.expect(std.mem.indexOf(u8, sentinel_owner.db_path, "store-dependency-check.db") == null);

    var conn_a = try sqlite_c.Conn.openFile(a.db_path, true);
    var conn_a_open = true;
    defer if (conn_a_open) conn_a.close() catch {};
    var conn_b = try sqlite_c.Conn.openFile(b.db_path, true);
    var conn_b_open = true;
    defer if (conn_b_open) conn_b.close() catch {};
    try conn_a.exec("CREATE TABLE t(k TEXT PRIMARY KEY); INSERT INTO t VALUES('a');");
    try conn_b.exec("CREATE TABLE t(k TEXT PRIMARY KEY); INSERT INTO t VALUES('b');");
    try conn_a.close();
    conn_a_open = false;
    try conn_b.close();
    conn_b_open = false;

    const ra = try runMode(.seed, a.db_path);
    const rb = try runMode(.seed, b.db_path);
    try std.testing.expectEqualStrings("ok", ra.integrity[0..ra.integrity_len]);
    try std.testing.expectEqualStrings("ok", rb.integrity[0..rb.integrity_len]);

    var a_rel_buf: [64]u8 = undefined;
    const a_rel = try std.fmt.bufPrint(&a_rel_buf, ".zig-cache/tmp/{s}", .{&a.name});
    var b_rel_buf: [64]u8 = undefined;
    const b_rel = try std.fmt.bufPrint(&b_rel_buf, ".zig-cache/tmp/{s}", .{&b.name});
    var sentinel_dir_buf: [64]u8 = undefined;
    const sentinel_dir = try std.fmt.bufPrint(&sentinel_dir_buf, ".zig-cache/tmp/{s}", .{&sentinel_owner.name});

    a.cleanup();
    try std.testing.expectError(error.FileNotFound, cwd.access(io, a_rel, .{}));
    try cwd.access(io, sentinel_dir, .{});
    try cwd.access(io, b_rel, .{});
    var sentinel_buf: [32]u8 = undefined;
    const sentinel_after_a = try cwd.readFile(io, sentinel_rel, &sentinel_buf);
    try std.testing.expectEqualStrings("SENTINEL-BYTES", sentinel_after_a);
    const reopen_b = try runMode(.reopen, b.db_path);
    try std.testing.expectEqualStrings("ok", reopen_b.integrity[0..reopen_b.integrity_len]);

    b.cleanup();
    try std.testing.expectError(error.FileNotFound, cwd.access(io, b_rel, .{}));
    try cwd.access(io, sentinel_dir, .{});
    const sentinel_after_b = try cwd.readFile(io, sentinel_rel, &sentinel_buf);
    try std.testing.expectEqualStrings("SENTINEL-BYTES", sentinel_after_b);
}

test "evidence format requires complete identity fields and write is fallible" {
    var line_buf: [512]u8 = undefined;
    const empty = Report{};
    try std.testing.expectError(error.EvidenceFormat, formatLineWithIdentity(&line_buf, .seed, empty, "3.53.4", sqlite_c.expected_source_id));
    try std.testing.expectError(error.EvidenceFormat, formatLineWithIdentity(&line_buf, .seed, filledReport(), "", sqlite_c.expected_source_id));
    try std.testing.expectError(error.EvidenceFormat, formatLineWithIdentity(&line_buf, .seed, filledReport(), "3.53.4", ""));
    const line = try formatLine(&line_buf, .seed, filledReport());
    try std.testing.expect(std.mem.indexOf(u8, line, "version=3.53.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "source_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "journal=wal") != null);
    try std.testing.expect(std.mem.startsWith(u8, line, "sqlite_dependency_probe "));
    try std.testing.expect(std.mem.indexOf(u8, line, "passed=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "sqlite_dependency_probe passed=1\n") == null);

    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var owned = try OwnedDbDir.create(allocator, io);
    defer owned.cleanup();
    const evidence_path = try std.Io.Dir.path.join(allocator, &.{ owned.dir_path, "evidence.txt" });
    defer allocator.free(evidence_path);
    var file = try std.Io.Dir.cwd().createFile(io, evidence_path, .{});
    try writeEvidence(io, file, line);
    file.close(io);
    var read_buf: [512]u8 = undefined;
    const got = try std.Io.Dir.cwd().readFile(io, evidence_path, &read_buf);
    try std.testing.expectEqualStrings(line, got);
}
