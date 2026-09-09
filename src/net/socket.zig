// net/socket — Socket layer (Analog: net/socket.c, net/ipv4/af_inet.c)
// Clean UseCase: socket() / bind() / send() / recv() orchestrate net_device + skbuff + net
const std = @import("std");
const printk = @import("../lib/printk.zig");
const skbuff = @import("skbuff.zig");
const net_core = @import("net_core.zig");
const netdev = @import("../drivers/net/net_device.zig");
const proc_mod = @import("../proc/proc.zig");

pub const AF_UNIX: usize = 1;
pub const AF_INET: usize = 2;
pub const SOCK_STREAM: usize = 1;
pub const SOCK_DGRAM: usize = 2;
pub const SOCK_RAW: usize = 3;
pub const SOCK_NONBLOCK: usize = 0x4000;
pub const SOCK_CLOEXEC: usize = 0x8000;

pub const MSG_DONTWAIT: usize = 0x80;
pub const MSG_PEEK: usize = 0x2;

const MAX_SOCK: usize = 16;

pub const SocketState = enum {
    uninitialized,
    bound,
    listening,
    connected,
    closed,
};

pub const Socket = struct {
    fd: i32 = -1,
    domain: usize = 0,
    sock_type: usize = 0,
    proto: usize = 0,
    state: SocketState = .uninitialized,
    bound_addr: [32]u8 = [_]u8{0} ** 32,
    bound_len: usize = 0,
    peer_addr: [32]u8 = [_]u8{0} ** 32,
    peer_len: usize = 0,
    // For connected sockets (e.g. socketpair)
    peer_socket: ?*Socket = null,
    // Backlog for listening sockets
    backlog: usize = 0,
    // Unix domain socket buffer
    rx_queue: []u8 = &[_]u8{},
    rx_len: usize = 0,
    rx_cap: usize = 0,
};

var socks: [MAX_SOCK]?Socket = [_]?Socket{null} ** MAX_SOCK;
var sock_count: usize = 0;
var next_fd: i32 = 100; // avoid collision with VFS fds 0..31

pub fn init() void {
    for (&socks) |*slot| slot.* = null;
    sock_count = 0;
    next_fd = 100;
    // clear unix buffers len
    for (&unix_buf_1) |*b| b.* = 0;
    for (&unix_buf_2) |*b| b.* = 0;
    printk.printk(.info, "net: socket layer ready (AF_UNIX, AF_INET, STREAM/DGRAM/RAW)", .{});
}

pub fn socketCreate(domain: usize, sock_type: usize, proto: usize) !i32 {
    // Strip SOCK_NONBLOCK/SOCK_CLOEXEC from type
    const base_type = sock_type & ~(SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (sock_count >= MAX_SOCK) return error.NoMem;
    for (&socks, 0..) |*slot, i| if (slot.* == null) {
        const fd = next_fd;
        next_fd += 1;
        slot.* = .{
            .fd = fd,
            .domain = domain,
            .sock_type = base_type,
            .proto = proto,
            .state = .uninitialized,
        };
        sock_count += 1;
        println("[INFO] net: socket fd={d} domain={d} type={d} proto={d} (slot {d})\n",
            .{ fd, domain, base_type, proto, i });
        return fd;
    };
    return error.NoMem;
}

pub fn findSock(fd: i32) ?*Socket {
    for (&socks) |*slot| if (slot.*) |*s| if (s.fd == fd) return s;
    return null;
}

pub fn bind(fd: i32, addr: []const u8) !void {
    const s = findSock(fd) orelse return error.NotFound;
    const n = @min(addr.len, s.bound_addr.len);
    @memcpy(s.bound_addr[0..n], addr[0..n]);
    s.bound_len = n;
    s.state = .bound;
    println("[INFO] net: bind fd={d} addr_len={d}\n", .{ fd, n });
}

pub fn listen(fd: i32, backlog: i32) !void {
    const s = findSock(fd) orelse return error.NotFound;
    s.backlog = @max(backlog, 0);
    s.state = .listening;
    println("[INFO] net: listen fd={d} backlog={d}\n", .{ fd, backlog });
}

pub fn accept(fd: i32) !i32 {
    const s = findSock(fd) orelse return error.NotFound;
    _ = s;
    // Simplified: no actual queued connections — return EAGAIN
    return error.Again;
}

pub fn getpeername(fd: i32, addr_ptr: usize, len_ptr: usize) !isize {
    const s = findSock(fd) orelse return error.NotFound;
    if (s.state != .connected) return error.NotConn;
    const addr = @as([*]u8, @ptrFromInt(addr_ptr))[0..s.peer_len];
    @memcpy(addr, s.peer_addr[0..s.peer_len]);
    if (len_ptr != 0) {
        const lp = @as(*usize, @ptrFromInt(len_ptr));
        lp.* = s.peer_len;
    }
    return @intCast(s.peer_len);
}

pub fn connect(fd: i32, addr: []const u8) !void {
    const s = findSock(fd) orelse return error.NotFound;
    const n = @min(addr.len, s.peer_addr.len);
    @memcpy(s.peer_addr[0..n], addr[0..n]);
    s.peer_len = n;
    s.state = .connected;
    println("[INFO] net: connect fd={d} addr_len={d}\n", .{ fd, n });
}

pub fn send(fd: i32, data: []const u8) !usize {
    const s = findSock(fd) orelse return error.NotFound;
    if (s.domain == AF_UNIX and s.peer_socket != null) {
        // AF_UNIX: send directly to peer's rx buffer
        const peer = s.peer_socket.?;
        const n = @min(data.len, peer.rx_queue.len - peer.rx_len);
        if (n == 0) return error.Again;
        @memcpy(peer.rx_queue[peer.rx_len..peer.rx_len + n], data[0..n]);
        peer.rx_len += n;
        return n;
    }
    // AF_INET: go through netdev
    const dev = netdev.first() orelse return error.NoDevice;
    const skb = skbuff.alloc() orelse return error.NoMem;
    const payload = skb.put(data.len);
    @memcpy(payload, data);
    skb.dev = dev.name;
    skb.protocol = 0x0800;
    try netdev.transmit(dev, skb);
    println("[INFO] net: send fd={d} {d}B via '{s}'\n", .{ fd, data.len, dev.name });
    return data.len;
}

pub fn recv(fd: i32, buf: []u8) !usize {
    const s = findSock(fd) orelse return error.NotFound;
    if (s.domain == AF_UNIX and s.peer_socket != null) {
        // AF_UNIX: read from local rx buffer
        if (s.rx_len == 0) return error.Again;
        const n = @min(buf.len, s.rx_len);
        @memcpy(buf[0..n], s.rx_queue[0..n]);
        // Shift remaining data
        const remaining = s.rx_len - n;
        if (remaining > 0) {
            @memcpy(s.rx_queue[0..remaining], s.rx_queue[n..s.rx_len]);
        }
        s.rx_len = remaining;
        return n;
    }
    // AF_INET: read from loopback queue
    if (net_core.recvFromQueue(buf)) |n| {
        println("[INFO] net: recv fd={d} → {d}B\n", .{ fd, n });
        return n;
    } else {
        return error.Again;
    }
}

pub fn recvmsg(fd: i32, msg_ptr: usize, flags: usize) !usize {
    _ = fd; _ = msg_ptr; _ = flags;
    // Simplified: just receive from loopback queue
    var buf: [2048]u8 = undefined;
    if (net_core.recvFromQueue(&buf)) |n| {
        // Copy to user msg structure would go here
        return n;
    }
    return error.Again;
}

pub fn socketpair(domain: usize, sock_type: usize, proto: usize, ret: *[2]i32) !void {
    // Create two connected sockets
    const fd1 = try socketCreate(domain, sock_type, proto);
    const fd2 = try socketCreate(domain, sock_type, proto);
    const s1 = findSock(fd1) orelse return error.NoMem;
    const s2 = findSock(fd2) orelse return error.NoMem;
    s1.peer_socket = s2;
    s2.peer_socket = s1;
    s1.state = .connected;
    s2.state = .connected;
    // Allocate rx buffers for AF_UNIX socketpair
    if (domain == AF_UNIX) {
        s1.rx_queue = &unix_buf_1;
        s2.rx_queue = &unix_buf_2;
        s1.rx_cap = unix_buf_1.len;
        s2.rx_cap = unix_buf_2.len;
    }
    ret[0] = fd1;
    ret[1] = fd2;
}

// AF_UNIX socketpair buffer storage
var unix_buf_1: [2048]u8 = [_]u8{0} ** 2048;
var unix_buf_2: [2048]u8 = [_]u8{0} ** 2048;

pub fn closeSocket(fd: i32) void {
    for (&socks) |*slot| if (slot.*) |*s| if (s.fd == fd) {
        slot.* = null;
        sock_count -= 1;
        println("[INFO] net: close fd={d}\n", .{fd});
        return;
    };
}

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
