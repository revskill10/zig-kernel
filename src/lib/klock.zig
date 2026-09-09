// lib/klock — Spinlock/Mutex infrastructure (analog: vinix klock module)
// Clean: low-level primitive, used by proc, vfs, mm, net
const std = @import("std");
const katomic = @import("katomic.zig");

/// Spinlock: kernel-level mutex using atomic CAS
/// In hosted simulation, we use a busy-wait loop (analog to x86 `lock cmpxchg` + `pause`)
pub const Lock = struct {
    locked: bool = false,
    // interrupts state (always false in hosted sim)
    ints_saved: bool = false,

    pub fn acquire(self: *Lock) void {
        // Spin until we get the lock
        while (katomic.cas(&self.locked, false, true) == false) {
            // In bare-metal: `pause` instruction
            // Hosted sim: yield to allow progress
            std.Thread.yield() catch {};
        }
        // In real kernel: save/restore interrupt state
        // self.ints_saved = cpu.interrupts_enabled()
    }

    pub fn release(self: *Lock) void {
        katomic.store(&self.locked, false);
        // In real kernel: restore interrupt state
        // cpu.interrupt_toggle(self.ints_saved)
    }

    /// Try to acquire the lock once (non-blocking). Returns true if acquired.
    pub fn tryAcquire(self: *Lock) bool {
        return katomic.cas(&self.locked, false, true);
    }
};

/// Mutex with waiter support (analog to sleeping mutex, used by proc layer)
pub const Mutex = struct {
    lock: Lock = .{},
    owner: ?usize = null, // thread ID of owner
    waiters: u32 = 0,

    pub fn acquire(self: *Mutex) void {
        self.lock.acquire();
        self.owner = getTid();
    }

    pub fn release(self: *Mutex) void {
        self.owner = null;
        self.lock.release();
    }

    pub fn tryAcquire(self: *Mutex) bool {
        if (self.lock.tryAcquire()) {
            self.owner = getTid();
            return true;
        }
        return false;
    }

    fn getTid() usize {
        // In hosted sim, use thread id or 1
        return 1;
    }
};

/// Read-Copy-Update lock (simplification for hosted sim)
pub const RwLock = struct {
    write: Lock = .{},
    read: Lock = .{},
    reader_count: u32 = 0,

    pub fn acquireRead(self: *RwLock) void {
        self.read.acquire();
        self.reader_count += 1;
        if (self.reader_count == 1) {
            self.write.acquire();
        }
        self.read.release();
    }

    pub fn releaseRead(self: *RwLock) void {
        self.read.acquire();
        self.reader_count -= 1;
        if (self.reader_count == 0) {
            self.write.release();
        }
        self.read.release();
    }

    pub fn acquireWrite(self: *RwLock) void {
        self.write.acquire();
    }

    pub fn releaseWrite(self: *RwLock) void {
        self.write.release();
    }
};
