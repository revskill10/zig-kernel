// vfs — Virtual File System: super_block, inode, dentry, file, file_operations vtable
// Clean Adapters: file_operations is DIP interface. Concrete: ramfs (analog to ext4), tmpfs, devtmpfs.
const std = @import("std");
const printk = @import("../lib/printk.zig");
const pipe_mod = @import("../drivers/pipe.zig");

pub const MAX_INODES: usize = 128;
pub const MAX_DENTRIES: usize = 128;
pub const MAX_OPEN_FILES: usize = 256;
pub const MAX_MOUNTS: usize = 16;
pub const FNAME_MAX: usize = 64;
pub const DIRENT_RECLEN: usize = @sizeOf(stat_mod.Dirent);

pub const SEEK_SET: i32 = 0;
pub const SEEK_CUR: i32 = 1;
pub const SEEK_END: i32 = 2;

pub const AT_FDCWD: i32 = -100;
pub const AT_REMOVEDIR: u32 = 0x200;
pub const AT_SYMLINK_FOLLOW: u32 = 0x400;
pub const AT_SYMLINK_NOFOLLOW: u32 = 0x100;
pub const O_RDONLY: u32 = 0;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const O_TRUNC: u32 = 0o1000;
pub const O_DIRECTORY: u32 = 0o200000;
pub const O_CLOEXEC: u32 = 0o2000000;

pub const FileType = enum { regular, directory, character, block, socket, symlink };
pub const Inode = struct {
    ino: u32,
    ftype: FileType,
    mode: u16 = 0o644,
    size: usize = 0,
    data: ?[]u8 = null,
    ops: ?*const FileOps = null,
    is_dev: bool = false,
    dev_id: u64 = 0,
};

pub const FileOps = struct {
    open: ?*const fn (*File) isize = null,
    read: ?*const fn (*File, []u8) isize = null,
    write: ?*const fn (*File, []const u8) isize = null,
    seek: ?*const fn (*File, i64, i32) isize = null,
    pread: ?*const fn (*File, u64, []u8) isize = null,
    ioctl: ?*const fn (*File, u32, usize) isize = null,
    release: ?*const fn (*File) void = null,
};

pub const Dentry = struct {
    name: [FNAME_MAX]u8 = [_]u8{0} ** FNAME_MAX,
    name_len: usize = 0,
    inode: ?*Inode = null,
    parent: ?*Dentry = null,
    children: [32]?*Dentry = [_]?*Dentry{null} ** 32,
    child_count: usize = 0,
    symlink_target: ?[]const u8 = null,
    fn setName(self: *Dentry, n: []const u8) void {
        const l = @min(n.len, FNAME_MAX - 1);
        @memcpy(self.name[0..l], n[0..l]);
        self.name_len = l;
    }
    pub fn nameSlice(self: *const Dentry) []const u8 { return self.name[0..self.name_len]; }
};

pub const File = struct {
    dentry: ?*Dentry = null,
    inode: ?*Inode = null,
    pos: usize = 0,
    flags: u32 = 0,
    ops: ?*const FileOps = null,
    data: ?*anyopaque = null,
    pipe_read_end: bool = false,
};

// Mount table
pub const MountEntry = struct {
    target: []const u8 = "",
    fs_type: []const u8 = "",
    root_dentry: ?*Dentry = null,
    flags: u32 = 0,
};

var inodes: [MAX_INODES]Inode = undefined;
var dentries: [MAX_DENTRIES]Dentry = undefined;
var inode_used: [MAX_INODES]bool = [_]bool{false} ** MAX_INODES;
var dentry_used: [MAX_DENTRIES]bool = [_]bool{false} ** MAX_DENTRIES;
var inode_next: u32 = 1;
var root_dentry: ?*Dentry = null;
var mounts: [MAX_MOUNTS]MountEntry = [_]MountEntry{.{}} ** MAX_MOUNTS;
var mount_count: usize = 0;

// M5 isolated workspaces: jail root + FS quota.
// Jail confines absolute-path resolution to a subtree (/workspace).
// `..` above jail clamps (never escapes); symlinks never followed by lookup.
// Quota caps total ramfs bytes; over-cap writes fail -28 ENOSPC.
var jail_root: ?*Dentry = null;
pub const FS_CAP_BYTES: usize = 32 << 20; // guest ramfs cap (mirrors workspace_mib default)
var fs_used_bytes: usize = 0;
pub fn fsUsed() usize { return fs_used_bytes; }

/// Charge growth against the FS cap. Returns false when over cap (ENOSPC).
fn fsCharge(growth: usize) bool {
    if (fs_used_bytes + growth > FS_CAP_BYTES) return false;
    if (fs_used_bytes + growth < fs_used_bytes) return false; // wrapped
    fs_used_bytes += growth;
    return true;
}

fn fsRelease(n: usize) void {
    fs_used_bytes = if (n > fs_used_bytes) 0 else fs_used_bytes - n;
}

// Global open file table (shared across processes for hosted sim)
var open_files: [MAX_OPEN_FILES]File = undefined;
var open_used: [MAX_OPEN_FILES]bool = [_]bool{false} ** MAX_OPEN_FILES;

pub fn init() void {
    for (&inode_used) |*u| u.* = false;
    for (&dentry_used) |*u| u.* = false;
    for (&open_used) |*u| u.* = false;
    for (&inodes) |*i| i.* = .{ .ino = 0, .ftype = .regular };
    for (&dentries) |*d| d.* = .{};
    for (&open_files) |*f| f.* = .{};
    for (&mounts) |*m| m.* = .{};
    inode_next = 1;
    root_dentry = null;
    dev_count = 0;
    mount_count = 0;
    jail_root = null; // M5: no jail until setJail
    fs_used_bytes = 0; // M5: quota accounting restarts (createFile charges below)
    root_dentry = allocDentry();
    const root_inode = allocInode(.directory) orelse unreachable;
    root_inode.mode = 0o755;
    root_dentry.?.setName("/");
    root_dentry.?.inode = root_inode;
    _ = createFile("/hello.txt", "Hello from Zig Linux VFS (ramfs)\n");
    _ = createFile("/etc/hostname", "zig-linux\n");
    _ = mkdiratImpl(AT_FDCWD, "/dev", 0o755) orelse {};
    _ = mkdiratImpl(AT_FDCWD, "/tmp", 0o777) orelse {};
    _ = createFile("/sbin/init", "#!/bin/sh\necho 'Hello from init'\n");
    printk.printk(.info, "vfs: ramfs mounted at / (ino={d}), VFS vtables ready", .{root_inode.ino});
}

// ── Inode/Dentry allocation ──
fn allocInode(ftype: FileType) ?*Inode {
    for (&inode_used, 0..) |*u, i| if (!u.*) {
        u.* = true;
        inodes[i] = .{ .ino = inode_next, .ftype = ftype };
        inode_next += 1;
        return &inodes[i];
    };
    return null;
}
fn allocDentry() ?*Dentry {
    for (&dentry_used, 0..) |*u, i| if (!u.*) {
        u.* = true;
        dentries[i] = .{};
        return &dentries[i];
    };
    return null;
}

fn freeDentrySlot(d: *Dentry) void {
    for (&dentries, 0..) |*slot, idx| {
        if (slot == d) {
            dentry_used[idx] = false;
            return;
        }
    }
}

fn releaseInodeSlot(ino: *Inode) void {
    for (&inodes, 0..) |*slot, idx| {
        if (slot == ino) {
            inode_used[idx] = false;
            return;
        }
    }
}

fn basename(path: []const u8) []const u8 {
    const lastSlash = std.mem.lastIndexOf(u8, path, "/") orelse return path;
    return path[lastSlash + 1..];
}

// ── Mount-aware hierarchical dentry traversal ──
/// Walk dentry children for a single component. O(32) fixed scan.
/// Fallback: linear scan of all dentries (for legacy flat-layout entries not in parent.children).
fn lookupChild(parent: *Dentry, component: []const u8) ?*Dentry {
    // Children tree walk
    for (parent.children[0..parent.child_count]) |child_opt| {
        if (child_opt) |child| {
            if (std.mem.eql(u8, child.nameSlice(), component)) return child;
        }
    }
    // Flat fallback for legacy dentries not in parent.children
    for (0..MAX_DENTRIES) |i| {
        if (dentry_used[i]) {
            const d = &dentries[i];
            if (d.inode != null) {
                if (d.parent) |p| {
                    if (p == parent and std.mem.eql(u8, d.nameSlice(), component)) return d;
                }
            }
        }
    }
    return null;
}

/// Split path into [start_dentry, component]. start_dentry is mount-aware.
fn mountStart(target_path: []const u8) *Dentry {
    var start = root_dentry.?;
    for (mounts[0..mount_count]) |m| {
        if (m.root_dentry) |mnt_root| {
            if (m.target.len > 0 and std.mem.eql(u8, m.target, target_path)) {
                start = mnt_root;
            }
        }
    }
    return start;
}

/// Walk path components from start dentry. O(depth * 32).
pub fn lookupPath(start: *Dentry, path: []const u8) ?*Dentry {
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (name.len == 0) return start;
    var current = start;
    var it = std.mem.tokenizeScalar(u8, name, '/');
    while (it.next()) |component| {
        const child = lookupChild(current, component) orelse return null;
        current = child;
    }
    return current;
}

/// Resolve path with dirfd (vinix parity). dirfd == AT_FDCWD uses root.
/// M5: when a jail is set, absolute paths resolve then must be jail-or-
/// descendant (ancestor walk) — escapes return null. Relative paths resolve
/// under the jail (no per-process cwd in hosted sim).
/// ponytail: unopened numeric dirfd falls back to root (hosted sim has no
/// per-test proc fd state; Linux would EBADF). ceiling: per-process cwd/fd table.
pub fn resolvePath(dirfd: i32, path: []const u8) ?*Dentry {
    const jail = jail_root;
    if (jail == null) return resolveRaw(dirfd, path);
    if (path.len == 0) return null;
    if (path[0] == '/') {
        const d = lookupPath(root_dentry.?, path) orelse return null;
        var cur: ?*Dentry = d;
        while (cur) |c| {
            if (c == jail.?) return d;
            cur = c.parent;
        }
        return null; // outside jail — escape denied
    }
    return lookupPath(jail.?, path);
}

fn resolveRaw(dirfd: i32, path: []const u8) ?*Dentry {
    const start = if (dirfd == AT_FDCWD) root_dentry.? else blk: {
        // dirfd should be an open directory file
        const f = fileAt(@intCast(dirfd)) orelse break :blk root_dentry.?;
        break :blk f.dentry orelse root_dentry.?;
    };
    return lookupPath(start, path);
}

// Keep old lookup for compat (flat scan, used by few callers)
pub fn lookup(path: []const u8) ?*Dentry {
    return lookupPath(root_dentry.?, path);
}

pub fn createFile(path: []const u8, content: []const u8) ?*Dentry {
    const rel = if (path.len > 0 and path[0] == '/') path[1..] else path;
    const name = basename(rel);
    const d = allocDentry() orelse return null;
    const ino = allocInode(.regular) orelse {
        freeDentrySlot(d);
        return null;
    };
    d.setName(name);
    d.inode = ino;
    // Parent = containing dir (M5: basename fix — nested paths resolve by component).
    const parent_path = if (std.mem.lastIndexOf(u8, rel, "/")) |idx| rel[0..idx] else "";
    if (parent_path.len > 0) {
        d.parent = lookup(parent_path) orelse root_dentry;
    } else {
        d.parent = root_dentry;
    }
    // Register as child of parent
    if (d.parent) |p| {
        if (p.child_count < 32) {
            p.children[p.child_count] = d;
            p.child_count += 1;
        }
    }
    // Allocate backing data
    if (!fsCharge(content.len)) {
        freeDentrySlot(d);
        releaseInodeSlot(ino);
        return null; // M5: ENOSPC at creation
    }
    const data = std.heap.page_allocator.alloc(u8, content.len) catch {
        fsRelease(content.len);
        freeDentrySlot(d);
        releaseInodeSlot(ino);
        return null;
    };
    @memcpy(data, content);
    ino.data = data;
    ino.size = content.len;
    ino.ops = &ramfs_ops;
    return d;
}

pub fn mkdiratImpl(dirfd: i32, path: []const u8, mode: u32) ?*Dentry {
    _ = dirfd;
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    const d = allocDentry() orelse return null;
    const ino = allocInode(.directory) orelse return null;
    d.setName(name);
    d.inode = ino;
    // Register as child of root (simplified: single-level for now)
    d.parent = root_dentry;
    if (root_dentry) |root| {
        if (root.child_count < 32) {
            root.children[root.child_count] = d;
            root.child_count += 1;
        }
    }
    ino.mode = @intCast(mode);
    ino.ops = &ramfs_ops;
    return d;
}

pub fn openat(dirfd: i32, path: []const u8, flags: u32, mode: u32) ?*File {
    const d = resolvePath(dirfd, path) orelse return null;
    if (d.inode == null and (flags & O_CREAT) != 0) {
        const new_d = createFile(path, &[_]u8{}) orelse return null;
        if (new_d.inode) |inode| {
            inode.mode = @intCast(mode & 0o7777 | 0o644);
        }
        return openFile(new_d, flags);
    }
    if (d.inode == null) return null;
    return openFile(d, flags);
}

fn openFile(dentry: *Dentry, flags: u32) ?*File {
    for (&open_used, 0..) |*u, i| if (!u.*) {
        u.* = true;
        open_files[i] = .{ .dentry = dentry, .inode = dentry.inode, .pos = 0, .flags = flags };
        return &open_files[i];
    };
    return null;
}

pub fn fdTable() *[MAX_OPEN_FILES]?*File {
    return &open_files;
}

pub fn fileAt(fd: usize) ?*File {
    if (fd >= MAX_OPEN_FILES) return null;
    if (!open_used[fd]) return null;
    return &open_files[fd];
}

pub fn close(f: *File) void {
    const idx = (@intFromPtr(f) - @intFromPtr(&open_files[0])) / @sizeOf(File);
    if (idx < MAX_OPEN_FILES) {
        open_used[idx] = false;
    }
}

pub fn open(path: []const u8) ?*File {
    return openat(AT_FDCWD, path, O_RDONLY, 0);
}

// ── Pipe integration ──
const PipeOps = FileOps{
    .read = pipeFileRead,
    .write = pipeFileWrite,
    .seek = null,
    .pread = null,
    .ioctl = null,
    .release = pipeFileRelease,
};

fn pipeFileRead(file: *File, buf: []u8) isize {
    const pipe = @as(*pipe_mod.Pipe, @ptrCast(@alignCast(file.data.?)));
    return pipe_mod.read(pipe, buf);
}

fn pipeFileWrite(file: *File, data: []const u8) isize {
    const pipe = @as(*pipe_mod.Pipe, @ptrCast(@alignCast(file.data.?)));
    return pipe_mod.write(pipe, data);
}

fn pipeFileRelease(file: *File) void {
    if (file.data) |data| {
        const pipe = @as(*pipe_mod.Pipe, @ptrCast(@alignCast(data)));
        _ = pipe;
    }
}

pub fn openFileFromPipe(p: *pipe_mod.Pipe, is_read_end: bool) ?*File {
    for (&open_used, 0..) |*u, i| if (!u.*) {
        u.* = true;
        open_files[i] = .{
            .dentry = null,
            .inode = null,
            .pos = 0,
            .flags = 0,
            .data = @ptrCast(p),
            .ops = &PipeOps,
            .pipe_read_end = is_read_end,
        };
        return &open_files[i];
    };
    return null;
}

pub fn allocFd(file: *File) ?usize {
    var i: usize = 3;
    while (i < MAX_OPEN_FILES) : (i += 1) {
        if (!open_used[i]) {
            open_used[i] = true;
            open_files[i] = file.*;
            return i;
        }
    }
    return null;
}

// ── File operations via vtable ──
fn ramfs_read(file: *File, buf: []u8) isize {
    const inode = file.inode orelse return -2;
    const data = inode.data orelse return 0;
    const avail = if (file.pos < data.len) data.len - file.pos else 0;
    const n = @min(buf.len, avail);
    @memcpy(buf[0..n], data[file.pos .. file.pos + n]);
    file.pos += n;
    return @intCast(n);
}

fn ramfs_write(file: *File, data_in: []const u8) isize {
    const inode = file.inode orelse return -2;
    const new_len = file.pos + data_in.len;
    if (inode.data == null or new_len > inode.data.?.len) {
        // M5: quota — growth beyond cap fails ENOSPC, contained to this file.
        const old_len = if (inode.data) |old| old.len else 0;
        const growth = if (new_len > old_len) new_len - old_len else 0;
        if (!fsCharge(growth)) return -28; // -ENOSPC
        const new_data = std.heap.page_allocator.alloc(u8, new_len) catch {
            fsRelease(growth);
            return -12;
        };
        if (inode.data) |old| {
            @memcpy(new_data[0..@min(old.len, new_len)], old[0..@min(old.len, new_len)]);
            std.heap.page_allocator.free(old);
        }
        // Net accounting: +new_len (fresh alloc) -old_len (freed) == +growth. Already +growth.
        inode.data = new_data;
    }
    @memcpy(inode.data.?[file.pos .. file.pos + data_in.len], data_in);
    file.pos += data_in.len;
    inode.size = @max(inode.size, file.pos);
    return @intCast(data_in.len);
}

fn ramfs_seek(file: *File, offset: i64, whence: i32) isize {
    const inode = file.inode orelse return -2;
    const new_pos: isize = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => @as(isize, @intCast(file.pos)) + offset,
        SEEK_END => @as(isize, @intCast(inode.size)) + offset,
        else => return -22,
    };
    if (new_pos < 0 or new_pos > @max(inode.size, 0)) return -22;
    file.pos = @intCast(new_pos);
    return new_pos;
}

fn ramfs_pread(file: *File, offset: u64, buf: []u8) isize {
    const inode = file.inode orelse return -2;
    const data = inode.data orelse return 0;
    if (offset >= data.len) return 0;
    const avail = data.len - offset;
    const n = @min(buf.len, avail);
    @memcpy(buf[0..n], data[offset..offset + n]);
    return @intCast(n);
}

fn ramfs_ioctl(file: *File, cmd: u32, arg: usize) isize {
    _ = file; _ = cmd; _ = arg;
    return 0;
}

fn ramfs_release(file: *File) void {
    _ = file;
}

pub const ramfs_ops = FileOps{
    .open = null,
    .read = ramfs_read,
    .write = ramfs_write,
    .seek = ramfs_seek,
    .pread = ramfs_pread,
    .ioctl = ramfs_ioctl,
    .release = ramfs_release,
};

// ── File operations (VFS-level API) ──
pub fn read(f: *File, buf: []u8) isize {
    if (f.ops) |ops| {
        if (ops.read) |func| return func(f, buf);
    }
    const ops = f.inode.?.ops orelse return -38;
    const func = ops.read orelse return -38;
    return func(f, buf);
}

pub fn write(f: *File, data: []const u8) isize {
    if (f.ops) |ops| {
        if (ops.write) |func| return func(f, data);
    }
    const ops = f.inode.?.ops orelse return -38;
    const func = ops.write orelse return -38;
    return func(f, data);
}

pub fn seek(f: *File, offset: i64, whence: i32) isize {
    if (f.ops) |ops| {
        if (ops.seek) |func| return func(f, offset, whence);
    }
    const ops = f.inode.?.ops orelse return -38;
    if (ops.seek) |func| return func(f, offset, whence);
    return -38;
}

pub fn pread(f: *File, offset: u64, buf: []u8) !usize {
    const ops = f.inode.?.ops orelse return error.Io;
    if (ops.pread) |func| {
        const n = func(f, offset, buf);
        return if (n < 0) error.Io else @intCast(n);
    }
    return error.Io;
}

// ── High-level FS operations ──
pub fn chdir(path: []const u8) bool {
    _ = path;
    return true;
}

pub fn getcwd() []const u8 {
    return "/";
}

pub fn mkdirat(dirfd: i32, path: []const u8, mode: u32) bool {
    _ = dirfd;
    return mkdiratImpl(path, mode) != null;
}

pub fn unlinkat(dirfd: i32, path: []const u8, flags: u32) bool {
    _ = dirfd; _ = flags;
    if (lookup(path)) |d| {
        if (d.inode) |inode| {
            for (&inode_used, 0..) |*u, i| {
                if (&inodes[i] == inode) {
                    u.* = false;
                    break;
                }
            }
        }
        return true;
    }
    return false;
}

// ── Mount table operations (vinix parity) ──
pub fn mount(source: []const u8, target: []const u8, fs_type: []const u8, flags: u32, data: usize) bool {
    _ = source; _ = data;
    if (mount_count >= MAX_MOUNTS) return false;
    // Find target dentry via hierarchical lookup
    const td = lookupPath(root_dentry.?, target) orelse return false;
    // Check for duplicate mount
    for (mounts[0..mount_count]) |m| {
        if (m.root_dentry) |existing| {
            if (existing == td) return false;
        }
    }
    mounts[mount_count] = .{
        .target = target,
        .fs_type = fs_type,
        .root_dentry = td,
        .flags = flags,
    };
    mount_count += 1;
    printk.printk(.info, "vfs: mounted {s} at {s}", .{ fs_type, target });
    return true;
}

pub fn umount(target: []const u8, flags: u32) bool {
    _ = flags;
    var found: ?usize = null;
    for (mounts[0..mount_count], 0..) |m, i| {
        if (m.target.len > 0 and std.mem.eql(u8, m.target, target)) {
            found = i;
            break;
        }
    }
    if (found) |idx| {
        // Compact
        var j = idx;
        while (j < mount_count - 1) : (j += 1) {
            mounts[j] = mounts[j + 1];
        }
        mount_count -= 1;
        printk.printk(.info, "vfs: umounted {s}", .{target});
        return true;
    }
    return false;
}

pub fn readlinkat(dirfd: i32, path: []const u8, buf: []u8, len: usize) isize {
    _ = dirfd; _ = len;
    const d = lookup(path) orelse return -2;
    if (d.symlink_target) |target| {
        const n = @min(buf.len, target.len);
        @memcpy(buf[0..n], target[0..n]);
        return @intCast(n);
    }
    return -2;
}

pub fn linkat(old_dirfd: i32, old_path: []const u8, new_dirfd: i32, new_path: []const u8, flags: u32) bool {
    _ = old_dirfd; _ = new_dirfd; _ = flags;
    const old_d = lookup(old_path) orelse return false;
    const new_name = if (new_path.len > 0 and new_path[0] == '/') new_path[1..] else new_path;
    const new_d = allocDentry() orelse return false;
    new_d.setName(new_name);
    new_d.inode = old_d.inode;
    new_d.parent = root_dentry;
    return true;
}

pub fn fchmod(fd: usize, mode: u32) bool {
    if (fd >= MAX_OPEN_FILES) return false;
    const f = &open_files[fd];
    if (f.inode) |inode| {
        inode.mode = @intCast(mode & 0o7777 | (inode.mode & 0o170000));
        return true;
    }
    return false;
}

// ── Stat support ──
pub const stat_mod = @import("../stat/stat.zig");

pub fn fstat(fd: usize, stat_buf: ?*stat_mod.Stat) bool {
    if (fd >= MAX_OPEN_FILES) return false;
    if (!open_used[fd]) return false;
    const f = &open_files[fd];
    const inode = f.inode orelse return false;
    if (stat_buf) |sb| {
        sb.dev = 0;
        sb.ino = inode.ino;
        sb.nlink = 1;
        sb.mode = @intCast(inode.mode);
        sb.uid = 0;
        sb.gid = 0;
        sb.pad0 = 0;
        sb.rdev = 0;
        sb.size = @intCast(inode.size);
        sb.blksize = 4096;
        sb.blocks = @intCast(@divTrunc(inode.size + 511, 512));
        sb.atim = .{ .tv_sec = 0, .tv_nsec = 0 };
        sb.mtim = .{ .tv_sec = 0, .tv_nsec = 0 };
        sb.ctim = .{ .tv_sec = 0, .tv_nsec = 0 };
    }
    return true;
}

pub fn fstatat(dirfd: i32, path: []const u8, stat_buf: ?*stat_mod.Stat, flags: u32) bool {
    const d = resolvePath(dirfd, path) orelse return false;
    const inode = d.inode orelse return false;
    if (stat_buf) |sb| {
        sb.dev = 0;
        sb.ino = inode.ino;
        sb.nlink = 1;
        sb.mode = @intCast(inode.mode);
        sb.uid = 0;
        sb.gid = 0;
        sb.pad0 = 0;
        sb.rdev = 0;
        sb.size = @intCast(inode.size);
        sb.blksize = 4096;
        sb.blocks = @intCast(@divTrunc(inode.size + 511, 512));
        sb.atim = .{ .tv_sec = 0, .tv_nsec = 0 };
        sb.mtim = .{ .tv_sec = 0, .tv_nsec = 0 };
        sb.ctim = .{ .tv_sec = 0, .tv_nsec = 0 };
    }
    _ = flags;
    return true;
}

// ── readdir support (vinix parity: vfs_readdir) ──
pub const Dirent = stat_mod.Dirent;

pub fn readdir(fd: usize, buf_ptr: usize, count: usize) isize {
    if (fd >= MAX_OPEN_FILES) return -9;
    if (!open_used[fd]) return -9;
    const f = &open_files[fd];
    const inode = f.inode orelse return -2;
    if (!stat_mod.isdir(inode.mode)) return -28;

    const d = f.dentry orelse return -2;
    const buf = @as([*]u8, @ptrFromInt(buf_ptr))[0..count];
    var offset: usize = 0;
    var idx: usize = 0;
    while (idx < d.child_count and offset + DIRENT_RECLEN <= count) : (idx += 1) {
        if (d.children[idx]) |child| {
            const child_ino = if (child.inode) |ino| ino.ino else 0;
            const child_name = child.nameSlice();
            const child_type = if (child.inode) |ino| stat_mod.direntType(ino.mode) else 0;
            const rec = @as(*stat_mod.Dirent, @ptrCast(@alignCast(&buf[offset])));
            rec.ino = @intCast(child_ino);
            rec.off = @intCast(idx * DIRENT_RECLEN);
            rec.reclen = DIRENT_RECLEN;
            rec.type = child_type;
            const copy_len = @min(child_name.len, 22);
            @memcpy(rec.name[0..copy_len], child_name[0..copy_len]);
            rec.name[copy_len] = 0;
            offset += DIRENT_RECLEN;
        }
    }
    return @intCast(offset);
}

// ── devtmpfs integration ──
var dev_nodes: [32]struct { name: []const u8, inode: *Inode } = undefined;
var dev_count: usize = 0;

pub fn devtmpfsRegister(name: []const u8, ops: *const FileOps) ?*Dentry {
    const dev_dir = lookupPath(root_dentry.?, "dev") orelse return null;
    const d = allocDentry() orelse return null;
    const ino = allocInode(.character) orelse return null;
    d.setName(name);
    d.inode = ino;
    d.parent = dev_dir;
    ino.mode = 0o666;
    ino.ops = ops;
    ino.is_dev = true;
    ino.dev_id = dev_count;
    // Register as child of /dev
    if (dev_dir.child_count < 32) {
        dev_dir.children[dev_dir.child_count] = d;
        dev_dir.child_count += 1;
    }
    dev_nodes[dev_count] = .{ .name = name, .inode = ino };
    dev_count += 1;
    printk.printk(.info, "vfs: devtmpfs: registered /dev/{s} (ino={d})", .{ name, ino.ino });
    return d;
}

pub fn devtmpfsPopulate() void {
    _ = devtmpfsRegister("null", &null_dev_ops);
    _ = devtmpfsRegister("console", &console_dev_ops);
    _ = devtmpfsRegister("zero", &zero_dev_ops);
    _ = devtmpfsRegister("full", &full_dev_ops);
    _ = devtmpfsRegister("random", &zero_dev_ops);
    _ = devtmpfsRegister("urandom", &zero_dev_ops);
    printk.printk(.info, "vfs: devtmpfs auto-populated {d} device nodes", .{dev_count});
}

// ── Character device ops ──
fn nullDevRead(file: *File, buf: []u8) isize {
    _ = file; _ = buf;
    return 0;
}

fn nullDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    return @intCast(data.len);
}

const null_dev_ops = FileOps{
    .read = nullDevRead,
    .write = nullDevWrite,
    .seek = null,
    .pread = null,
    .ioctl = null,
    .release = null,
};

fn consoleDevRead(file: *File, buf: []u8) isize {
    _ = file; _ = buf;
    return 0;
}

fn consoleDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    std.debug.print("{s}", .{data});
    return @intCast(data.len);
}

const console_dev_ops = FileOps{
    .read = consoleDevRead,
    .write = consoleDevWrite,
    .seek = null,
    .pread = null,
    .ioctl = null,
    .release = null,
};

fn zeroDevRead(file: *File, buf: []u8) isize {
    _ = file;
    for (buf) |*b| b.* = 0;
    return @intCast(buf.len);
}

fn zeroDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    return @intCast(data.len);
}

const zero_dev_ops = FileOps{
    .read = zeroDevRead,
    .write = zeroDevWrite,
    .seek = null,
    .pread = null,
    .ioctl = null,
    .release = null,
};

fn fullDevRead(file: *File, buf: []u8) isize {
    _ = file; _ = buf;
    return -28;
}

fn fullDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    _ = data;
    return -28;
}

const full_dev_ops = FileOps{
    .read = fullDevRead,
    .write = fullDevWrite,
    .seek = null,
    .pread = null,
    .ioctl = null,
    .release = null,
};

// ── M5 isolated workspaces: jail + reset ──

/// Confine absolute-path resolution to the subtree at jail_path (e.g. "/workspace").
/// Creates it if missing. Returns false when path unusable.
pub fn setJail(jail_path: []const u8) bool {
    const d = lookup(jail_path) orelse {
        // auto-create single-level dir under root
        const created = mkdiratImpl(AT_FDCWD, jail_path, 0o755) orelse return false;
        jail_root = created;
        return true;
    };
    jail_root = d;
    return true;
}

pub fn clearJail() void {
    jail_root = null;
}

/// Resolve path under jail: absolute paths re-rooted at jail, `..` clamped at
/// jail root (never escapes), `.`/`//` normalized. Relative paths resolve from
/// jail root too (no per-process cwd in hosted sim).
/// Symlinks are never followed by lookup — escape via link impossible.
pub fn resolveJailed(path: []const u8) ?*Dentry {
    const jail = jail_root orelse return resolvePath(AT_FDCWD, path);
    if (path.len == 0) return null;
    // Absolute guest paths carry the jail prefix (/workspace/...) — strip it.
    // Other absolute paths re-root at jail (leading / dropped below).
    var rel = path;
    if (std.mem.startsWith(u8, rel, "/workspace/")) {
        rel = rel["/workspace".len..];
    } else if (std.mem.eql(u8, rel, "/workspace")) {
        return jail;
    }
    const stripped = if (rel.len > 0 and rel[0] == '/') rel[1..] else rel;
    // normalize into small stack buffer
    var norm: [512]u8 = undefined;
    var parts: [64][]const u8 = undefined;
    var depth: usize = 0;
    var it = std.mem.tokenizeScalar(u8, stripped, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (depth > 0) depth -= 1; // clamp at jail root
            continue;
        }
        if (depth >= parts.len) return null;
        parts[depth] = c;
        depth += 1;
    }
    var n: usize = 0;
    for (parts[0..depth]) |p| {
        if (n != 0) {
            if (n >= norm.len) return null;
            norm[n] = '/';
            n += 1;
        }
        if (n + p.len > norm.len) return null;
        @memcpy(norm[n .. n + p.len], p);
        n += p.len;
    }
    if (n == 0) return jail; // path == jail root itself
    return lookupPath(jail, norm[0..n]);
}

/// M5 reset: destroy all children under jail (frees inode data + accounting),
/// leaving the jail dir itself. Returns files removed.
pub fn clearJailContents() usize {
    const jail = jail_root orelse return 0;
    var removed: usize = 0;
    var i: usize = 0;
    while (i < jail.child_count) {
        const child = jail.children[i] orelse {
            i += 1;
            continue;
        };
        freeDentryTree(child);
        removed += 1;
        // swap-remove
        jail.children[i] = jail.children[jail.child_count - 1];
        jail.children[jail.child_count - 1] = null;
        jail.child_count -= 1;
    }
    return removed;
}

fn freeDentryTree(d: *Dentry) void {
    // recurse children first
    var i: usize = 0;
    while (i < d.child_count) {
        if (d.children[i]) |c| freeDentryTree(c);
        i += 1;
    }
    d.child_count = 0;
    if (d.inode) |ino| {
        if (ino.data) |data| {
            fsRelease(data.len);
            std.heap.page_allocator.free(data);
            ino.data = null;
        }
        ino.size = 0;
        releaseInodeSlot(ino);
    }
    freeDentrySlot(d);
}
