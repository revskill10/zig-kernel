// net/net_core — netif layer (Analog: net/core/dev.c)
// Receives sk_buff from driver ISR → delivers to socket RX queue (simulation of netif_rx)
const std = @import("std");
const printk = @import("../lib/printk.zig");
const skbuff = @import("skbuff.zig");

// Simple per-socket RX queue: global loopback for demo (real kernel: per-socket sk_receive_queue)
const RX_QUEUE: usize = 32;
var rx_queue: [RX_QUEUE]?*skbuff.SkBuff = [_]?*skbuff.SkBuff{null} ** RX_QUEUE;
var rx_head: usize = 0;
var rx_tail: usize = 0;
var rx_len: usize = 0;

pub fn init() void {
    // drain stale loopback skbs — makes init idempotent across unit tests
    for (0..RX_QUEUE) |i| {
        if (rx_queue[i]) |skb| {
            skbuff.free(skb);
            rx_queue[i] = null;
        }
    }
    rx_head = 0;
    rx_tail = 0;
    rx_len = 0;
    printk.printk(.info, "net_core: netif layer ready", .{});
}

/// Called by driver ISR (analog to netif_rx / napi_gro_receive)
pub fn netifRx(skb: *skbuff.SkBuff) void {
    if (rx_len >= RX_QUEUE) {
        printk.printk(.warn, "net_core: RX queue full, dropping {d}B", .{skb.len});
        skbuff.free(skb);
        return;
    }
    rx_queue[rx_tail] = skb;
    rx_tail = (rx_tail + 1) % RX_QUEUE;
    rx_len += 1;
    printk.printk(.debug, "net_core: netif_rx {d}B (qlen={d})", .{ skb.len, rx_len });
}

pub fn recvFromQueue(buf: []u8) ?usize {
    if (rx_len == 0) return null;
    const skb = rx_queue[rx_head].?;
    const n = @min(buf.len, skb.len);
    @memcpy(buf[0..n], skb.slice()[0..n]);
    const remaining = skb.len - n;
    if (remaining > 0) {
        @memcpy(skb.data[0..remaining], skb.slice()[n..]);
        skb.head = 0; skb.tail = remaining; skb.len = remaining;
        return n;
    }
    skbuff.free(skb);
    rx_queue[rx_head] = null;
    rx_head = (rx_head + 1) % RX_QUEUE;
    rx_len -= 1;
    return n;
}

pub fn queueLen() usize { return rx_len; }
pub fn flush() void {
    // explicit drain for tests that want clean state without re-init log spam
    for (0..RX_QUEUE) |i| {
        if (rx_queue[i]) |skb| { skbuff.free(skb); rx_queue[i] = null; }
    }
    rx_head = 0; rx_tail = 0; rx_len = 0;
}
