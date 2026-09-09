// vfs — Virtual File System: super_block, inode, dentry, file, file_operations vtable
// Clean Adapters: file_operations is DIP interface. Concrete: ramfs (analog to ext4), tmpfs, devtmpfs.
const std = @import("std");
const printk = @import("../lib/printk.zig");
const pipe_mod = @import("../drivers/pipe.zig");

pub const MAX_INODES: usize = 128;
pub const MAX_DENTRIES: usize = 128;
pub const MAX_OPEN_FILES: usize = 256;
pub const FNAME_MAX: usize = 64;

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
    data: ?[]u8 = null, // ramfs tmpfs data
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
    children: [32]?*Dentry = [_]?*Dentry{null} ** 32, // Simple fixed-size child list
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

var inodes: [MAX_INODES]Inode = undefined;
var dentries: [MAX_DENTRIES]Dentry = undefined;
var inode_used: [MAX_INODES]bool = [_]bool{false} ** MAX_INODES;
var dentry_used: [MAX_DENTRIES]bool = [_]bool{false} ** MAX_DENTRIES;
var inode_next: u32 = 1;
var root_dentry: ?*Dentry = null;

// Global open file table (shared across processes for hosted sim)
var open_files: [MAX_OPEN_FILES]File = undefined;
var open_used: [MAX_OPEN_FILES]bool = [_]bool{false} ** MAX_OPEN_FILES;

pub fn init() void {
    root_dentry = allocDentry();
    const root_inode = allocInode(.directory) orelse unreachable;
    root_inode.mode = 0o755;
    root_dentry.?.setName("/");
    root_dentry.?.inode = root_inode;
    // Add pre-populated entries for demo
    _ = createFile("/hello.txt", "Hello from Zig Linux VFS (ramfs)\n");
    _ = createFile("/etc/hostname", "zig-linux\n");
    // Create /dev directory for devtmpfs
    _ = mkdiratImpl(AT_FDCWD, "/dev", 0o755) orelse {};
    _ = mkdiratImpl(AT_FDCWD, "/tmp", 0o777) orelse {};
    // Create /sbin/init placeholder
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

fn parentPath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    const lastSlash = std.mem.lastIndexOf(u8, path, "/") orelse return null;
    if (lastSlash == 0) return "/";
    return path[0..lastSlash];
}

fn basename(path: []const u8) []const u8 {
    const lastSlash = std.mem.lastIndexOf(u8, path, "/") orelse return path;
    return path[lastSlash + 1..];
}

pub fn lookup(path: []const u8) ?*Dentry {
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (name.len == 0) return root_dentry;
    // linear scan (dentry cache analog)
    for (&dentries, 0..) |*d, i| if (dentry_used[i]) {
        if (std.mem.eql(u8, d.nameSlice(), name)) return d;
    };
    return null;
}

// ── Path-based operations (vinix parity: resolvePath) ──
pub fn resolvePath(dirfd: i32, path: []const u8) ?*Dentry {
    _ = dirfd;
    if (path.len > 0 and path[0] == '/') {
        return lookup(path);
    }
    // Relative path — resolve against root for sim simplicity
    return lookup(path);
}

pub fn createFile(path: []const u8, content: []const u8) ?*Dentry {
    const name = if (path.len > 0 and path[0] == '/') path[1..] else path;
    const d = allocDentry() orelse return null;
    const ino = allocInode(.regular) orelse return null;
    d.setName(name);
    d.inode = ino;
    d.parent = root_dentry;
    // Allocate backing data
    const data = std.heap.page_allocator.alloc(u8, content.len) catch return null;
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
    d.parent = root_dentry;
    ino.mode = @intCast(mode);
    ino.ops = &ramfs_ops;
    return d;
}

pub fn openat(dirfd: i32, path: []const u8, flags: u32, mode: u32) ?*File {
    const d = resolvePath(dirfd, path) orelse return null;
    // Handle O_CREAT
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

// ── Convenience: open by path (O_RDONLY default) ──
pub fn open(path: []const u8) ?*File {
    return openat(AT_FDCWD, path, O_RDONLY, 0);
}

// ── Pipe integration: create a file backed by a pipe ──
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
        // Don't close pipe here — it's closed via pipe.close() when both ends are gone
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
    var i: usize = 3; // skip stdin/stdout/stderr
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
        const new_data = std.heap.page_allocator.alloc(u8, new_len) catch return -12;
        if (inode.data) |old| {
            @memcpy(new_data[0..@min(old.len, new_len)], old[0..@min(old.len, new_len)]);
            std.heap.page_allocator.free(old);
        }
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
    // Dispatch through file-level ops first (pipe), then inode ops (ramfs)
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
    return true; // Simplified: root is always cwd
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
    // Simplified: just mark inode as not used
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

pub fn mount(source: []const u8, target: []const u8, fs_type: []const u8, flags: u32, data: usize) bool {
    _ = source; _ = target; _ = fs_type; _ = flags; _ = data;
    return true; // Simplified
}

pub fn umount(target: []const u8, flags: u32) bool {
    _ = target; _ = flags;
    return true; // Simplified
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
        inode.mode = @intCast(mode & 0o7777 | (inode.mode & 0o170000)); // Preserve file type bits
        return true;
    }
    return false;
}

// ── Stat support (vinix parity: stat.Stat) ──
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
    if (fd >= MAX_OPEN_FILES) return -9; // -EBADF
    if (!open_used[fd]) return -9;
    const f = &open_files[fd];
    const inode = f.inode orelse return -2; // -ENOENT
    if (!stat_mod.isdir(inode.mode)) return -28; // -ENOTDIR

    // Simplified: emit the root directory's first entry
    // In full impl: walk dentry children, fill Dirent array
    _ = buf_ptr; _ = count;
    return 0;
}

// ── devtmpfs integration ──
// Auto-populated character devices (analog: vinix devtmpfs)
var dev_nodes: [32]struct { name: []const u8, inode: *Inode } = undefined;
var dev_count: usize = 0;

/// Register a char device under /dev (vinix parity: devtmpfs.register)
pub fn devtmpfsRegister(name: []const u8, ops: *const FileOps) ?*Dentry {
    const d = allocDentry() orelse return null;
    const ino = allocInode(.character) orelse return null;
    d.setName(name);
    d.inode = ino;
    d.parent = lookup("/dev") orelse root_dentry;
    ino.mode = 0o666;
    ino.ops = ops;
    ino.is_dev = true;
    ino.dev_id = dev_count;
    dev_nodes[dev_count] = .{ .name = name, .inode = ino };
    dev_count += 1;
    println("[INFO] vfs: devtmpfs: registered /dev/{s} (ino={d})\n", .{ name, ino.ino });
    return d;
}

/// Auto-populate /dev with standard devices after mount
pub fn devtmpfsPopulate() void {
    _ = devtmpfsRegister("null", &null_dev_ops);
    _ = devtmpfsRegister("console", &console_dev_ops);
    _ = devtmpfsRegister("zero", &zero_dev_ops);
    _ = devtmpfsRegister("full", &full_dev_ops);
    _ = devtmpfsRegister("random", &zero_dev_ops); // stub: returns zeros
    _ = devtmpfsRegister("urandom", &zero_dev_ops); // stub: returns zeros
    println("[INFO] vfs: devtmpfs auto-populated {d} device nodes\n", .{ dev_count });
}

// ── Character device ops for standard /dev nodes ──

fn nullDevRead(file: *File, buf: []u8) isize {
    _ = file; _ = buf;
    return 0; // EOF on read (vinix/dev/null analog)
}

fn nullDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    return @intCast(data.len); // discard all writes
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
    return 0; // simplex: no keyboard input in hosted sim
}

fn consoleDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    std.debug.print("{s}", .{data}); // echo to real stdout
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
    return @intCast(buf.len); // returns zero bytes
}

fn zeroDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    return @intCast(data.len); // discard
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
    return -28; // ENOSPC on read from /dev/full
}

fn fullDevWrite(file: *File, data: []const u8) isize {
    _ = file;
    _ = data;
    return -28; // ENOSPC — write always fails on /dev/full
}

const full_dev_ops = FileOps{
    .read = fullDevRead,
    .write = fullDevWrite,
    .seek = null,
    .pread = null,
    .ioctl = null,
    .release = null,
};

// Helper for println-style output (used by devtmpfs)
fn println(comptime fmt: []const u8, args: anytype) void {
    // Use std.debug.print directly with format string
    std.debug.print(fmt, args);
}
