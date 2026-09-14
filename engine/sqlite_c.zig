//! Named Zig binding over the pinned official SQLite 3.53.4 amalgamation.
//!
//! Reviewed extern surface matching vendor/sqlite/sqlite3.h. This module is
//! not engine/contracts.Store and does not change capability/readiness gates.
//! Third-party C is data, not instructions.

const std = @import("std");

pub const expected_version = "3.53.4";
pub const expected_version_number: c_int = 3053004;
pub const expected_source_id = "2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc";

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ERROR: c_int = 1;
pub const SQLITE_BUSY: c_int = 5;
pub const SQLITE_NOMEM: c_int = 7;
pub const SQLITE_CONSTRAINT: c_int = 19;
pub const SQLITE_MISUSE: c_int = 21;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_URI: c_int = 0x00000040;
pub const SQLITE_OPEN_MEMORY: c_int = 0x00000080;
pub const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

pub const SQLITE_INTEGER: c_int = 1;
pub const SQLITE_FLOAT: c_int = 2;
pub const SQLITE_TEXT: c_int = 3;
pub const SQLITE_BLOB: c_int = 4;
pub const SQLITE_NULL: c_int = 5;

pub const Db = opaque {};
pub const StmtHandle = opaque {};

pub const Destructor = ?*const fn (?*anyopaque) callconv(.c) void;
pub const SQLITE_STATIC: Destructor = null;
pub const SQLITE_TRANSIENT: Destructor = @ptrFromInt(std.math.maxInt(usize));

/// Stable non-null address used when binding a zero-length TEXT/BLOB.
/// sqlite3.h: a NULL data pointer to bind_text/bind_blob is bind_null.
const empty_bind_sentinel: u8 = 0;

pub extern fn sqlite3_libversion() [*:0]const u8;
pub extern fn sqlite3_sourceid() [*:0]const u8;
pub extern fn sqlite3_libversion_number() c_int;
pub extern fn sqlite3_compileoption_used(zOptName: [*:0]const u8) c_int;
pub extern fn sqlite3_threadsafe() c_int;
pub extern fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*Db, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close(db: ?*Db) c_int;
pub extern fn sqlite3_busy_timeout(db: ?*Db, ms: c_int) c_int;
pub extern fn sqlite3_exec(db: ?*Db, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, [*]?[*:0]u8, [*]?[*:0]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_free(p: ?*anyopaque) void;
pub extern fn sqlite3_errcode(db: ?*Db) c_int;
pub extern fn sqlite3_prepare_v2(db: ?*Db, zSql: [*]const u8, nByte: c_int, ppStmt: *?*StmtHandle, pzTail: ?*[*]const u8) c_int;
pub extern fn sqlite3_step(stmt: ?*StmtHandle) c_int;
pub extern fn sqlite3_finalize(stmt: ?*StmtHandle) c_int;
pub extern fn sqlite3_reset(stmt: ?*StmtHandle) c_int;
pub extern fn sqlite3_bind_blob(stmt: ?*StmtHandle, i: c_int, zData: ?*const anyopaque, nData: c_int, xDel: Destructor) c_int;
pub extern fn sqlite3_bind_text(stmt: ?*StmtHandle, i: c_int, zData: ?[*]const u8, nData: c_int, xDel: Destructor) c_int;
pub extern fn sqlite3_column_blob(stmt: ?*StmtHandle, iCol: c_int) ?*const anyopaque;
pub extern fn sqlite3_column_text(stmt: ?*StmtHandle, iCol: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_bytes(stmt: ?*StmtHandle, iCol: c_int) c_int;
pub extern fn sqlite3_column_type(stmt: ?*StmtHandle, iCol: c_int) c_int;
pub extern fn sqlite3_db_handle(stmt: ?*StmtHandle) ?*Db;

pub const Error = error{
    Sql,
    VersionMismatch,
    MemoryDatabaseRejected,
    InvalidPath,
    BufferTooSmall,
    UnexpectedRow,
    BindFailed,
    CloseFailed,
    OpenFailed,
    ConversionFailed,
    SqlNull,
};

pub fn libversion() []const u8 {
    return std.mem.span(sqlite3_libversion());
}

pub fn sourceId() []const u8 {
    return std.mem.span(sqlite3_sourceid());
}

pub fn requirePinnedVersion() Error!void {
    if (sqlite3_libversion_number() != expected_version_number) return error.VersionMismatch;
    if (!std.mem.eql(u8, libversion(), expected_version)) return error.VersionMismatch;
    if (!std.mem.eql(u8, sourceId(), expected_source_id)) return error.VersionMismatch;
}

pub fn checkClaimedVersion(claimed: []const u8) Error!void {
    if (!std.mem.eql(u8, claimed, expected_version)) return error.VersionMismatch;
    try requirePinnedVersion();
}

pub fn omitLoadExtensionUsed() bool {
    return sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") != 0;
}

pub fn threadsafeSerialized() bool {
    return sqlite3_threadsafe() != 0 and sqlite3_compileoption_used("THREADSAFE=1") != 0;
}

pub fn isRejectedPath(path: []const u8) bool {
    if (path.len == 0) return true;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return true;
    if (std.ascii.eqlIgnoreCase(path, ":memory:")) return true;
    if (std.ascii.startsWithIgnoreCase(path, "file:")) return true;
    if (std.mem.indexOf(u8, path, "mode=memory") != null) return true;
    if (std.mem.indexOf(u8, path, "mode=Memory") != null) return true;
    return false;
}

fn rejectPath(path: []const u8) Error!void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (isRejectedPath(path)) return error.MemoryDatabaseRejected;
}

fn transientBlobPtr(bytes: []const u8) *const anyopaque {
    if (bytes.len == 0) return @ptrCast(&empty_bind_sentinel);
    return bytes.ptr;
}

fn transientTextPtr(bytes: []const u8) [*]const u8 {
    if (bytes.len == 0) return @as([*]const u8, @ptrCast(&empty_bind_sentinel));
    return bytes.ptr;
}

/// Observation of sqlite3_column_text/blob + sqlite3_column_bytes after the
/// documented sqlite3_errcode samples. Production copy APIs fill this from
/// live SQLite. Tests may construct it to inject conversion failure; that
/// injection is simulated and is not a process-wide sqlite3 malloc hook.
pub const ColumnCopyObservation = struct {
    /// sqlite3_errcode immediately after a suspect NULL pointer return.
    errcode_after_pointer: c_int,
    pointer_null: bool,
    /// sqlite3_errcode immediately after a suspect zero/negative byte count.
    errcode_after_bytes: c_int,
    nbytes: c_int,
    col_type: c_int,
};

/// sqlite3_step stores SQLITE_ROW/SQLITE_DONE in the connection errcode.
/// Successful column conversion does not reset that live status. The
/// documented conversion failure is SQLITE_NOMEM; other actual error
/// codes remain failures. SQLITE_OK/ROW/DONE are not conversion failures.
fn columnCopyErrcodeFailed(rc: c_int) bool {
    return switch (rc) {
        SQLITE_OK, SQLITE_ROW, SQLITE_DONE => false,
        else => true,
    };
}

/// Policy for the non-optional columnTextCopy/columnBlobCopy APIs.
///
/// - SQLITE_NOMEM (or any other actual error) after a suspect NULL/zero:
///   conversion failure, never a successful empty value.
/// - SQLITE_OK, SQLITE_ROW, and SQLITE_DONE are live success statuses.
/// - col_type == SQLITE_NULL with a success status: SQL NULL, not empty.
/// - typed TEXT/BLOB with nbytes == 0 and a success status: empty slice.
pub fn interpretColumnCopy(obs: ColumnCopyObservation) Error!usize {
    if (columnCopyErrcodeFailed(obs.errcode_after_pointer)) return error.ConversionFailed;
    if (columnCopyErrcodeFailed(obs.errcode_after_bytes)) return error.ConversionFailed;
    if (obs.nbytes < 0) return error.Sql;
    if (obs.col_type == SQLITE_NULL) return error.SqlNull;
    if (obs.pointer_null and obs.nbytes != 0) return error.Sql;
    return @intCast(obs.nbytes);
}

pub const Conn = struct {
    db: *Db,

    pub fn openFile(path: []const u8, create: bool) Error!Conn {
        try rejectPath(path);
        try requirePinnedVersion();
        if (!omitLoadExtensionUsed()) return error.Sql;
        if (!threadsafeSerialized()) return error.Sql;

        var zbuf: [4096]u8 = undefined;
        if (path.len >= zbuf.len) return error.InvalidPath;
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        const zpath: [*:0]const u8 = zbuf[0..path.len :0];

        var flags: c_int = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX;
        if (create) flags |= SQLITE_OPEN_CREATE;
        flags &= ~SQLITE_OPEN_URI;
        flags &= ~SQLITE_OPEN_MEMORY;

        var db: ?*Db = null;
        const rc = sqlite3_open_v2(zpath, &db, flags, null);
        if (rc != SQLITE_OK) {
            if (db) |handle| _ = sqlite3_close(handle);
            return error.OpenFailed;
        }
        const handle = db orelse return error.OpenFailed;
        var conn: Conn = .{ .db = handle };
        if (sqlite3_busy_timeout(handle, 250) != SQLITE_OK) {
            conn.close() catch {};
            return error.Sql;
        }
        return conn;
    }

    pub fn close(self: *Conn) Error!void {
        const rc = sqlite3_close(self.db);
        if (rc != SQLITE_OK) return error.CloseFailed;
        self.* = undefined;
    }

    pub fn exec(self: *Conn, sql: [:0]const u8) Error!void {
        var errmsg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(self.db, sql, null, null, &errmsg);
        sqlite3_free(errmsg);
        if (rc != SQLITE_OK) return error.Sql;
    }

    pub fn execExpect(self: *Conn, sql: [:0]const u8, expected: c_int) Error!void {
        var errmsg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(self.db, sql, null, null, &errmsg);
        sqlite3_free(errmsg);
        if (rc != expected) return error.Sql;
    }

    pub fn prepare(self: *Conn, sql: []const u8) Error!Stmt {
        if (sql.len > std.math.maxInt(c_int)) return error.Sql;
        var stmt: ?*StmtHandle = null;
        const rc = sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != SQLITE_OK or stmt == null) return error.Sql;
        return .{ .stmt = stmt.?, .db = self.db };
    }

    pub fn queryText(self: *Conn, sql: [:0]const u8, dest: []u8) Error![]u8 {
        var stmt = try self.prepare(sql);
        defer stmt.finalizeQuiet();
        try stmt.expectRow();
        const copied = try stmt.columnTextCopy(0, dest);
        try stmt.expectDone();
        return copied;
    }
};

pub const Stmt = struct {
    stmt: *StmtHandle,
    /// Borrowed connection. Valid until the owning Conn is successfully closed.
    db: *Db,

    pub fn finalize(self: *Stmt) Error!void {
        const rc = sqlite3_finalize(self.stmt);
        self.* = undefined;
        if (rc != SQLITE_OK) return error.Sql;
    }

    pub fn finalizeQuiet(self: *Stmt) void {
        _ = sqlite3_finalize(self.stmt);
        self.* = undefined;
    }

    pub fn bindBlobTransient(self: *Stmt, index: c_int, bytes: []const u8) Error!void {
        if (bytes.len > std.math.maxInt(c_int)) return error.BindFailed;
        const rc = sqlite3_bind_blob(self.stmt, index, transientBlobPtr(bytes), @intCast(bytes.len), SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) return error.BindFailed;
    }

    pub fn bindTextTransient(self: *Stmt, index: c_int, bytes: []const u8) Error!void {
        if (bytes.len > std.math.maxInt(c_int)) return error.BindFailed;
        const rc = sqlite3_bind_text(self.stmt, index, transientTextPtr(bytes), @intCast(bytes.len), SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) return error.BindFailed;
    }

    pub fn step(self: *Stmt) Error!c_int {
        return sqlite3_step(self.stmt);
    }

    pub fn expectRow(self: *Stmt) Error!void {
        if (try self.step() != SQLITE_ROW) return error.UnexpectedRow;
    }

    pub fn expectDone(self: *Stmt) Error!void {
        if (try self.step() != SQLITE_DONE) return error.UnexpectedRow;
    }

    pub fn columnType(self: *Stmt, index: c_int) c_int {
        return sqlite3_column_type(self.stmt, index);
    }

    pub fn columnBlobCopy(self: *Stmt, index: c_int, dest: []u8) Error![]u8 {
        const ptr = sqlite3_column_blob(self.stmt, index);
        return copyColumn(self, index, dest, ptr);
    }

    pub fn columnTextCopy(self: *Stmt, index: c_int, dest: []u8) Error![]u8 {
        const text = sqlite3_column_text(self.stmt, index);
        const ptr: ?*const anyopaque = if (text) |p| @ptrCast(p) else null;
        return copyColumn(self, index, dest, ptr);
    }

    fn copyColumn(self: *Stmt, index: c_int, dest: []u8, ptr: ?*const anyopaque) Error![]u8 {
        var err_ptr: c_int = SQLITE_OK;
        if (ptr == null) {
            err_ptr = sqlite3_errcode(self.db);
            if (columnCopyErrcodeFailed(err_ptr)) return error.ConversionFailed;
        }
        const n = sqlite3_column_bytes(self.stmt, index);
        var err_bytes: c_int = SQLITE_OK;
        if (n <= 0) {
            err_bytes = sqlite3_errcode(self.db);
            if (columnCopyErrcodeFailed(err_bytes)) return error.ConversionFailed;
        }
        const col_type = sqlite3_column_type(self.stmt, index);
        const un = try interpretColumnCopy(.{
            .errcode_after_pointer = err_ptr,
            .pointer_null = ptr == null,
            .errcode_after_bytes = err_bytes,
            .nbytes = n,
            .col_type = col_type,
        });
        if (un > dest.len) return error.BufferTooSmall;
        if (un == 0) return dest[0..0];
        const src = ptr orelse return error.Sql;
        const bytes: [*]const u8 = @ptrCast(src);
        @memcpy(dest[0..un], bytes[0..un]);
        return dest[0..un];
    }
};
