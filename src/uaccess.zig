// uaccess — checked user-memory copy gate (M2).
// Validates user pointers against mm VMAs + prot + low-half range before copy.
// Hosted sim shares address space, so copy is memcpy after validation.
// Baremetal: same gate, physical copy via mapped frames.
// ponytail: cross-VMA spans rejected (single-VMA only); ceiling: iovec walk.
const builtin = @import("builtin");
const mm = @import("mm/mm.zig");
const gdt = @import("arch/x86_64/gdt.zig");

pub const MAX_CSTR: usize = 4096;

/// Strict gate on both targets: an address with no containing VMA is rejected.
/// Hosted tests map VMAs with MAP_FIXED over real backing for positive cases;
/// wild pointers fail closed instead of dereferencing the host address space.
/// ponytail: cross-VMA spans rejected (single-VMA only); ceiling: iovec walk.
pub fn validate(addr: usize, len: usize, write: bool) bool {
    if (len == 0) return true;
    const end = addr +% len;
    if (end < addr) return false; // wrap
    if (!gdt.isUserRange(addr, len)) return false; // kernel half / non-canonical
    const vma = mm.findVma(addr) orelse return false; // no VMA, no copy
    if (end > vma.end) return false; // single-VMA only
    return gdt.userCopyAllowed(vma.start, vma.end, vma.prot, addr, len, write);
}

pub fn copyFromUser(dst: []u8, user_src: usize) bool {
    if (!validate(user_src, dst.len, false)) return false;
    const src = @as([*]const u8, @ptrFromInt(user_src))[0..dst.len];
    @memcpy(dst, src);
    return true;
}

pub fn copyToUser(user_dst: usize, src: []const u8) bool {
    if (!validate(user_dst, src.len, true)) return false;
    const dst = @as([*]u8, @ptrFromInt(user_dst))[0..src.len];
    @memcpy(dst, src);
    return true;
}

/// Bounded NUL-terminated string copy. Returns length or null on reject/overrun.
pub fn copyCStrFromUser(user_src: usize, out: []u8) ?usize {
    const vma = mm.findVma(user_src);
    var i: usize = 0;
    while (i < out.len and i < MAX_CSTR) : (i += 1) {
        const a = user_src +% i;
        if (a < user_src) return null; // wrap
        if (!gdt.isUserRange(a, 1)) return null;
        if (vma) |v| {
            if (a >= v.end) return null;
            if ((v.prot & mm.PROT_READ) == 0) return null;
        } else return null; // no VMA, no copy (both targets)
        const c = @as(*const u8, @ptrFromInt(a)).*;
        out[i] = c;
        if (c == 0) return i;
    }
    return null;
}
