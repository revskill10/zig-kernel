// supervisor/workspace — isolated workspace policy (M5).
// Path confinement + quota accounting + reset. Pure, host-testable.
// Real FS enforcement (openat2 RESOLVE_IN_ROOT, symlink race handling,
// block quotas) lands on Linux in M7; this is the testable policy ceiling.
const std = @import("std");

pub const MAX_PATH: usize = 4096;
pub const PREFIX = "/workspace";

/// Resolve client path to canonical in-workspace relative path.
/// Absolute `/workspace/...` only. `.`/`//` normalized, `..` above root rejected.
/// Returns relative path (no leading slash). Errors: BadPath | Escape | TooLong.
pub fn resolve(req: []const u8, out: []u8) ![]u8 {
    if (req.len == 0 or req.len > MAX_PATH) return error.BadPath;
    for (req) |c| if (c == 0) return error.BadPath;
    if (!std.mem.startsWith(u8, req, PREFIX)) return error.BadPath;
    const rest = req[PREFIX.len..];
    if (rest.len != 0 and rest[0] != '/') return error.BadPath;

    // split + normalize with depth tracking
    var parts: [128][]const u8 = undefined;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (depth == 0) return error.Escape;
            depth -= 1;
            continue;
        }
        if (depth >= parts.len) return error.BadPath;
        parts[depth] = p;
        depth += 1;
    }
    if (depth == 0) return error.BadPath; // bare "/workspace" is a dir, not a file
    var n: usize = 0;
    for (parts[0..depth]) |p| {
        if (n != 0) {
            if (n >= out.len) return error.BadPath;
            out[n] = '/';
            n += 1;
        }
        if (n + p.len > out.len) return error.BadPath;
        @memcpy(out[n .. n + p.len], p);
        n += p.len;
    }
    return out[0..n];
}

/// Symlinks: never followed for workspace ops. Link targets confined too.
pub fn checkLinkTarget(target: []const u8) !void {
    if (target.len == 0 or target.len > MAX_PATH) return error.BadPath;
    for (target) |c| if (c == 0) return error.BadPath;
    if (std.mem.startsWith(u8, target, "/")) {
        // absolute target must stay inside /workspace
        if (!std.mem.startsWith(u8, target, PREFIX ++ "/") and !std.mem.eql(u8, target, PREFIX)) return error.Escape;
        return;
    }
    // relative target: stored but never followed by supervisor ops; confined
    // at use time by resolve(). Creation rejects anything escaping its dir.
    var it = std.mem.splitScalar(u8, target, '/');
    var depth: isize = 0;
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            depth -= 1;
            if (depth < 0) return error.Escape;
            continue;
        }
        depth += 1;
    }
}

pub const Workspace = struct {
    cap_bytes: u64,
    used_bytes: u64 = 0,

    pub fn init(workspace_mib: u32) Workspace {
        return .{ .cap_bytes = @as(u64, workspace_mib) << 20 };
    }

    /// Account a write of n bytes. Saturating-safe. Error when over cap.
    pub fn charge(self: *Workspace, n: u64) !void {
        const next = self.used_bytes +% n;
        if (next < self.used_bytes) return error.QuotaExceeded; // wrapped
        if (next > self.cap_bytes) return error.QuotaExceeded;
        self.used_bytes = next;
    }

    pub fn release(self: *Workspace, n: u64) void {
        self.used_bytes = if (n > self.used_bytes) 0 else self.used_bytes - n;
    }

    /// Reset wipes usage (caller destroys storage + bumps generation first).
    pub fn reset(self: *Workspace) void {
        self.used_bytes = 0;
    }
};

test "workspace: resolve confines paths" {
    var out: [MAX_PATH]u8 = undefined;
    try std.testing.expectEqualStrings("tool", try resolve("/workspace/tool", &out));
    try std.testing.expectEqualStrings("a/b/c", try resolve("/workspace/a/./b//c", &out));
    try std.testing.expectEqualStrings("c", try resolve("/workspace/a/b/../../c", &out));
    try std.testing.expectError(error.Escape, resolve("/workspace/../etc/passwd", &out));
    try std.testing.expectError(error.Escape, resolve("/workspace/a/../../../x", &out));
    try std.testing.expectError(error.BadPath, resolve("/etc/passwd", &out));
    try std.testing.expectError(error.BadPath, resolve("workspace/tool", &out));
    try std.testing.expectError(error.BadPath, resolve("/workspace", &out));
    try std.testing.expectError(error.BadPath, resolve("/workspace-other/x", &out));
    try std.testing.expectError(error.BadPath, resolve("", &out));
}

test "workspace: link targets confined" {
    try checkLinkTarget("/workspace/data/out.txt");
    try checkLinkTarget("sub/dir/file");
    try std.testing.expectError(error.Escape, checkLinkTarget("/etc/passwd"));
    try std.testing.expectError(error.Escape, checkLinkTarget("../../etc/passwd"));
    try std.testing.expectError(error.Escape, checkLinkTarget("a/../../../../x"));
    try std.testing.expectError(error.BadPath, checkLinkTarget(""));
}

test "workspace: quota + reset" {
    var w = Workspace.init(32);
    try std.testing.expectEqual(@as(u64, 32 << 20), w.cap_bytes);
    try w.charge(1024);
    try w.charge((32 << 20) - 1024);
    try std.testing.expectError(error.QuotaExceeded, w.charge(1));
    try std.testing.expectError(error.QuotaExceeded, w.charge(0xFFFFFFFFFFFFFFFF));
    w.release(1024);
    try w.charge(1024);
    w.release(1 << 40); // over-release clamps to 0
    try std.testing.expectEqual(@as(u64, 0), w.used_bytes);
    try w.charge(100);
    w.reset();
    try std.testing.expectEqual(@as(u64, 0), w.used_bytes);
}
