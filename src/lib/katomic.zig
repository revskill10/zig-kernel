// lib/katomic — Atomic operations (analog: vinix katomic module)
// Clean: low-level atomic primitives using Zig's std.atomic.Value API
const std = @import("std");

/// Compare-and-swap: if *ptr == `expected`, set *ptr = `desired`
/// Returns true if swap succeeded, false otherwise.
pub fn cas(ptr: *volatile bool, expected: bool, desired: bool) bool {
    return @cmpxchgStrong(bool, ptr, expected, desired, .seq_cst, .seq_cst) == null;
}

/// Atomic increment, returns old value
pub fn inc(ptr: *volatile u32) u32 {
    return @atomicRmw(u32, ptr, .Add, 1, .seq_cst);
}

/// Atomic decrement, returns true if result is zero
pub fn dec(ptr: *volatile u32) bool {
    const old = @atomicRmw(u32, ptr, .Sub, 1, .seq_cst);
    return old - 1 == 0;
}

/// Atomic increment on u64, returns old value
pub fn inc64(ptr: *volatile u64) u64 {
    return @atomicRmw(u64, ptr, .Add, 1, .seq_cst);
}

/// Atomic decrement on u64, returns true if result is zero
pub fn dec64(ptr: *volatile u64) bool {
    const old = @atomicRmw(u64, ptr, .Sub, 1, .seq_cst);
    return old - 1 == 0;
}

/// Atomic store (sequentially consistent)
pub fn store(ptr: *volatile bool, value: bool) void {
    _ = @atomicRmw(bool, ptr, .Xchg, value, .seq_cst);
}

/// Atomic store u32
pub fn store32(ptr: *volatile u32, value: u32) void {
    _ = @atomicRmw(u32, ptr, .Xchg, value, .seq_cst);
}

/// Atomic store u64
pub fn store64(ptr: *volatile u64, value: u64) void {
    _ = @atomicRmw(u64, ptr, .Xchg, value, .seq_cst);
}

/// Atomic load bool (seq_cst)
pub fn load(ptr: *volatile bool) bool {
    return @atomicLoad(bool, ptr, .seq_cst);
}

/// Atomic load u32
pub fn load32(ptr: *volatile u32) u32 {
    return @atomicLoad(u32, ptr, .seq_cst);
}

/// Atomic load u64
pub fn load64(ptr: *volatile u64) u64 {
    return @atomicLoad(u64, ptr, .seq_cst);
}

/// BTS (bit test and set) — atomically set bit and return old value
pub fn bts32(ptr: *volatile u32, bit: u8) bool {
    const mask = @as(u32, 1) << bit;
    const old = @atomicRmw(u32, ptr, .Or, mask, .seq_cst);
    return (old & mask) != 0;
}

/// BTR (bit test and reset) — atomically clear bit and return old value
pub fn btr32(ptr: *volatile u32, bit: u8) bool {
    const mask = ~(@as(u32, 1) << bit);
    const old = @atomicRmw(u32, ptr, .And, mask, .seq_cst);
    return (old & ~mask) != 0;
}

// ── Type-erased atomic wrappers using std.atomic.Value ──

pub const AtomicBool = struct {
    value: std.atomic.Value(bool) = .init(false),

    pub fn init(start: bool) AtomicBool {
        return .{ .value = std.atomic.Value(bool).init(start) };
    }

    pub fn load(self: *const AtomicBool) bool {
        return self.value.load(.seq_cst);
    }

    pub fn store(self: *AtomicBool, val: bool) void {
        self.value.store(val, .seq_cst);
    }

    pub fn swap(self: *AtomicBool, val: bool) bool {
        return self.value.swap(val, .seq_cst);
    }

    pub fn cas(self: *AtomicBool, expected: bool, desired: bool) bool {
        return self.value.compareAndSwap(expected, desired, .seq_cst, .seq_cst) == null;
    }
};

pub const AtomicU32 = struct {
    value: std.atomic.Value(u32) = .init(0),

    pub fn init(start: u32) AtomicU32 {
        return .{ .value = std.atomic.Value(u32).init(start) };
    }

    pub fn load(self: *const AtomicU32) u32 {
        return self.value.load(.seq_cst);
    }

    pub fn store(self: *AtomicU32, val: u32) void {
        self.value.store(val, .seq_cst);
    }

    pub fn inc(self: *AtomicU32) u32 {
        return self.value.fetchAdd(1, .seq_cst);
    }

    pub fn dec(self: *AtomicU32) u32 {
        return self.value.fetchSub(1, .seq_cst);
    }

    pub fn cas(self: *AtomicU32, expected: u32, desired: u32) bool {
        return self.value.compareAndSwap(expected, desired, .seq_cst, .seq_cst) == null;
    }
};

pub const AtomicU64 = struct {
    value: std.atomic.Value(u64) = .init(0),

    pub fn init(start: u64) AtomicU64 {
        return .{ .value = std.atomic.Value(u64).init(start) };
    }

    pub fn load(self: *const AtomicU64) u64 {
        return self.value.load(.seq_cst);
    }

    pub fn store(self: *AtomicU64, val: u64) void {
        self.value.store(val, .seq_cst);
    }

    pub fn inc(self: *AtomicU64) u64 {
        return self.value.fetchAdd(1, .seq_cst);
    }

    pub fn dec(self: *AtomicU64) u64 {
        return self.value.fetchSub(1, .seq_cst);
    }

    pub fn cas(self: *AtomicU64, expected: u64, desired: u64) bool {
        return self.value.compareAndSwap(expected, desired, .seq_cst, .seq_cst) == null;
    }
};
