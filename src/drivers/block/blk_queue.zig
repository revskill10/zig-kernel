// drivers/block/blk_queue — fixed request ring over virtio_blk sectors.
// Analog: block/blk-core.c request queue (Linux). Bring-up model: 16-slot
// ring, synchronous dispatch to virtio_blk.read/write_sector, no IRQ/virtqueue
// yet. Freestanding-safe: no imports, no heap, static storage only.
// ponytail: no elevator/scheduler, no merging, no async completion, single
// device. ceiling: virtqueue avail/used rings + IRQ completion + io_uring.
const virtio_blk = @import("virtio_blk.zig");

pub const QUEUE_DEPTH: usize = 16;

pub const Op = enum { read, write };

pub const Request = struct {
    op: Op,
    lba: u32,
    done: bool = false,
    err: ?anyerror = null,
};

var ring: [QUEUE_DEPTH]?Request = [_]?Request{null} ** QUEUE_DEPTH;
var head: usize = 0;
var tail: usize = 0;
var count: usize = 0;
var completed: usize = 0;

pub fn init() void {
    for (&ring) |*s| s.* = null;
    head = 0;
    tail = 0;
    count = 0;
    completed = 0;
}

/// Submit a request; dispatches synchronously through virtio_blk.
/// Returns slot index. Errors: QueueFull, NotReady/OutOfRange via req.err.
pub fn submit(op: Op, lba: u32, buf: *[512]u8) !usize {
    if (count >= QUEUE_DEPTH) return error.QueueFull;
    const slot = tail;
    ring[slot] = .{ .op = op, .lba = lba };
    tail = (tail + 1) % QUEUE_DEPTH;
    count += 1;
    // Synchronous dispatch (no virtqueue yet)
    const req = &ring[slot].?;
    switch (op) {
        .read => virtio_blk.read_sector(lba, buf) catch |e| {
            req.err = e;
            req.done = true;
            completed += 1;
            return e;
        },
        .write => virtio_blk.write_sector(lba, buf) catch |e| {
            req.err = e;
            req.done = true;
            completed += 1;
            return e;
        },
    }
    req.done = true;
    completed += 1;
    return slot;
}

pub fn pending() usize {
    return count - completed;
}

pub fn depth() usize {
    return QUEUE_DEPTH;
}
