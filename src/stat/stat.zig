// stat — File type and metadata constants (analog: vinix stat module, Linux <sys/stat.h>)
// Clean: pure data/types only — no side effects.
const time = @import("../time/time.zig");

pub const ifmt: u32 = 0xf000;
pub const ifblk: u32 = 0x6000;
pub const ifchr: u32 = 0x2000;
pub const ififo: u32 = 0x1000;
pub const ifreg: u32 = 0x8000;
pub const ifdir: u32 = 0x4000;
pub const iflnk: u32 = 0xa000;
pub const ifsock: u32 = 0xc000;
pub const ifpipe: u32 = 0x3000;

pub fn isblk(mode: u32) bool {
    return (mode & ifmt) == ifblk;
}

pub fn ischr(mode: u32) bool {
    return (mode & ifmt) == ifchr;
}

pub fn isifo(mode: u32) bool {
    return (mode & ifmt) == ififo;
}

pub fn isreg(mode: u32) bool {
    return (mode & ifmt) == ifreg;
}

pub fn isdir(mode: u32) bool {
    return (mode & ifmt) == ifdir;
}

pub fn islnk(mode: u32) bool {
    return (mode & ifmt) == iflnk;
}

pub fn issock(mode: u32) bool {
    return (mode & ifmt) == ifsock;
}

pub fn ispipe(mode: u32) bool {
    return (mode & ifmt) == ifpipe;
}

/// Stat — matches Linux stat struct (analog: vinix stat.Stat)
pub const Stat = extern struct {
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u64 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    pad0: u32 = 0,
    rdev: u64 = 0,
    size: i64 = 0,
    blksize: i64 = 0,
    blocks: i64 = 0,
    atim: time.TimeSpec = .{},
    mtim: time.TimeSpec = .{},
    ctim: time.TimeSpec = .{},
    pad1: [3]i64 = [_]i64{0} ** 3,
};

/// Dirent — directory entry (analog: vinix stat.Dirent)
pub const Dirent = extern struct {
    ino: u64 = 0,
    off: u64 = 0,
    reclen: u16 = 0,
    type: u8 = 0,
    name: [1024]u8 = [_]u8{0} ** 1024,
};

pub const dtUnknown: u8 = 0;
pub const dtFifo: u8 = 1;
pub const dtChr: u8 = 2;
pub const dtDir: u8 = 4;
pub const dtBlk: u8 = 6;
pub const dtReg: u8 = 8;
pub const dtLnk: u8 = 10;
pub const dtSock: u8 = 12;
pub const dtWht: u8 = 14;

/// Map a file type mode to its dirent type
pub fn direntType(mode: u32) u8 {
    return if (isdir(mode)) dtDir
    else if (ischr(mode)) dtChr
    else if (isblk(mode)) dtBlk
    else if (isifo(mode)) dtFifo
    else if (islnk(mode)) dtLnk
    else if (issock(mode)) dtSock
    else dtReg;
}
