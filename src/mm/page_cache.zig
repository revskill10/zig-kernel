// mm/page_cache — 4KiB page cache keyed by (dev, block_nr).
// Analog: mm/filemap.c address_space (Linux). Bring-up model: 32-entry
// fully-associative cache, 8 sectors per page, read-through via caller
// reader fn, dirty/writeback via writer fn. Freestanding-safe: no imports,
// no heap, static storage. Keyed by u32 dev + u64 block.
// ponytail: no eviction policy beyond round-robin, no readahead, no
// writeback daemon, single address space. ceiling: LRU + readahead + pdflush.
pub const PAGE_SIZE: usize = 4096;
pub const SECTORS_PER_PAGE: usize = 8;
pub const CACHE_ENTRIES: usize = 32;

pub const Page = struct {
    dev: u32 = 0,
    block_nr: u64 = 0, // page-aligned block number (in 4K pages)
    valid: bool = false,
    dirty: bool = false,
    data: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE,
};

var cache: [CACHE_ENTRIES]Page = [_]Page{.{}} ** CACHE_ENTRIES;
var next_victim: usize = 0;
var hits: usize = 0;
var misses: usize = 0;

pub fn init() void {
    for (&cache) |*p| {
        p.valid = false;
        p.dirty = false;
    }
    next_victim = 0;
    hits = 0;
    misses = 0;
}

fn find(dev: u32, block_nr: u64) ?*Page {
    for (&cache) |*p| {
        if (p.valid and p.dev == dev and p.block_nr == block_nr) return p;
    }
    return null;
}

/// Read a 4K page through the cache. reader(lba sector, out []u8 slice of
/// exactly 512B) fills each sector. Returns pointer to cached page data.
/// Caller must copy out before next call may evict (round-robin).
pub fn read_page(dev: u32, block_nr: u64, reader: anytype) !*Page {
    if (find(dev, block_nr)) |p| {
        hits += 1;
        return p;
    }
    misses += 1;
    // Evict round-robin; write back dirty victim via writer is caller duty
    // (ponytail: dirty victim silently dropped if caller never flushed).
    const victim = &cache[next_victim];
    next_victim = (next_victim + 1) % CACHE_ENTRIES;
    const base_lba: u64 = block_nr * SECTORS_PER_PAGE;
    var off: usize = 0;
    var s: u64 = 0;
    while (s < SECTORS_PER_PAGE) : (s += 1) {
        try reader(base_lba + s, victim.data[off .. off + 512]);
        off += 512;
    }
    victim.dev = dev;
    victim.block_nr = block_nr;
    victim.valid = true;
    victim.dirty = false;
    return victim;
}

/// Mark cached page dirty (writeback pending).
pub fn mark_dirty(dev: u32, block_nr: u64) void {
    if (find(dev, block_nr)) |p| p.dirty = true;
}

/// Flush one dirty page via writer(lba, data []u8 const). Returns true if flushed.
pub fn flush_one(dev: u32, block_nr: u64, writer: anytype) !bool {
    const p = find(dev, block_nr) orelse return false;
    if (!p.dirty) return false;
    const base_lba: u64 = block_nr * SECTORS_PER_PAGE;
    var off: usize = 0;
    var s: u64 = 0;
    while (s < SECTORS_PER_PAGE) : (s += 1) {
        try writer(base_lba + s, p.data[off .. off + 512]);
        off += 512;
    }
    p.dirty = false;
    return true;
}

pub fn stats() struct { hits: usize, misses: usize } {
    return .{ .hits = hits, .misses = misses };
}
