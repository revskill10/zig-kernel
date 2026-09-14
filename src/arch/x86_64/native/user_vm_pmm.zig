// arch/x86_64/native/user_vm_pmm — native PMM / identity-map adapter for
// KWP3a.2a. Not invoked from the default kernel in this slice.
//
// allocPage/freePage/isAllocatable/inManagedDomain come from the real PMM.
// Live ownership is tracked per adapter in caller-owned storage: isAllocatable
// is boot eligibility only and is never treated as VM ownership.
// Native pageBytes translates a validated live owned frame through the
// supervisor identity map. Hosted tests install `page_bytes_resolver` so
// synthetic IDs are never turned into pointers. Physical frame zero is
// rejected and, when PMM accepts the return, released without forming a
// Zig null pointer. If PMM refuses that free, ownership is retained and
// 0 is returned to the caller so core cleanup can track it; a refused
// free is never reported as success.

const builtin = @import("builtin");
const pmm = @import("pmm");

pub const PAGE: u64 = 4096;

pub const AllocError = error{
    OutOfMemory,
    PhysicalZero,
    FrameUnaligned,
    FrameOutOfDomain,
    DuplicateFrame,
    ReservedFrame,
};

pub const AccessError = error{
    PageAccess,
    PhysicalZero,
    FrameUnaligned,
    FrameOutOfDomain,
    NotOwnedFrame,
};

/// Test seam: hosted PMM fixtures install a storage resolver. Null (default)
/// selects the native identity-map path. Never used to turn fixture IDs into
/// pointers from the pure constructor. Hosted non-freestanding builds refuse
/// the identity-pointer path even if the resolver is unset.
pub var page_bytes_resolver: ?*const fn (u64) AccessError!*[PAGE]u8 = null;

/// Per-adapter live-ownership tracker. `owned` is caller-owned bounded
/// storage (native callers place it in static BSS, not a kernel stack).
pub const Adapter = struct {
    owned: []u64 = &.{},
    count: usize = 0,

    pub fn init(storage: []u64) Adapter {
        return .{ .owned = storage, .count = 0 };
    }

    pub fn ownedCount(self: *const Adapter) usize {
        return self.count;
    }

    pub fn owns(self: *const Adapter, phys: u64) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.owned[i] == phys) return true;
        }
        return false;
    }

    pub fn allocPage(self: *Adapter) AllocError!u64 {
        if (self.count >= self.owned.len) return error.OutOfMemory;
        const p = pmm.allocPage() orelse return error.OutOfMemory;
        if (p == 0) {
            if (pmm.freePage(0)) return error.PhysicalZero;
            // PMM refused. Keep the frame so a later freePage(0) can retry
            // and so the core sees the outstanding zero. Capacity was
            // reserved before allocPage.
            self.owned[self.count] = 0;
            self.count += 1;
            return 0;
        }
        if (p % PAGE != 0) {
            _ = pmm.freePage(p);
            return error.FrameUnaligned;
        }
        if (!pmm.inManagedDomain(p)) {
            _ = pmm.freePage(p);
            return error.FrameOutOfDomain;
        }
        if (!pmm.isAllocatable(p)) {
            _ = pmm.freePage(p);
            return error.ReservedFrame;
        }
        if (self.owns(p)) return error.DuplicateFrame;
        self.owned[self.count] = p;
        self.count += 1;
        return p;
    }

    pub fn pageBytes(self: *Adapter, phys: u64) AccessError!*[PAGE]u8 {
        if (phys == 0) return error.PhysicalZero;
        if (phys % PAGE != 0) return error.FrameUnaligned;
        if (!pmm.inManagedDomain(phys)) return error.FrameOutOfDomain;
        if (!self.owns(phys)) return error.NotOwnedFrame;
        if (page_bytes_resolver) |resolver| return resolver(phys);
        if (comptime builtin.os.tag != .freestanding) return error.PageAccess;
        const addr: usize = @intCast(phys);
        const ptr: *[PAGE]u8 = @ptrFromInt(addr);
        return ptr;
    }

    pub fn freePage(self: *Adapter, phys: u64) bool {
        const idx = self.indexOf(phys) orelse return false;
        if (!pmm.freePage(phys)) return false;
        const last = self.count - 1;
        self.owned[idx] = self.owned[last];
        self.count = last;
        return true;
    }

    fn indexOf(self: *const Adapter, phys: u64) ?usize {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.owned[i] == phys) return i;
        }
        return null;
    }
};
