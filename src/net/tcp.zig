// net/tcp — Minimal TCP state machine over the socket layer.
// Analog: net/ipv4/tcp.c, net/ipv4/tcp_input.c (Linux).
// Bring-up model: loopback-only, no actual NIC/IRQ, no timer wheel.
// ponytail: no sequence numbers, no retransmit, no congestion control,
//   no checksum, no MSS negotiation, fixed buffer. Ceiling: real seq/ack
//   + retransmit + congestion + checksum + RTT estimation.
const std = @import("std");
const builtin = @import("builtin");

pub const TcpState = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    closing,
    time_wait,
};

pub const TcpEvent = enum {
    passive_open,
    active_open,
    send_syn,
    recv_syn,
    recv_syn_ack,
    send_ack,
    send_data,
    recv_data,
    send_fin,
    recv_fin,
    send_fin_ack,
    recv_fin_ack,
    timeout,
};

pub const TcpError = error{
    NotFound,
    NotConnected,
    InvalidState,
    BufferFull,
    BufferEmpty,
    Closed,
};

const MAX_TCP_SOCKS: usize = 8;
const RX_BUF_SIZE: usize = 4096;

pub const TcpSocket = struct {
    state: TcpState = .closed,
    fd: i32 = -1,
    remote_port: u16 = 0,
    local_port: u16 = 0,
    rx_buf: [RX_BUF_SIZE]u8 = undefined,
    rx_len: usize = 0,
    tx_buf: [RX_BUF_SIZE]u8 = undefined,
    tx_len: usize = 0,

    pub fn reset(self: *TcpSocket) void {
        self.state = .closed;
        self.fd = -1;
        self.remote_port = 0;
        self.local_port = 0;
        self.rx_len = 0;
        self.tx_len = 0;
    }
};

var tcp_socks: [MAX_TCP_SOCKS]?TcpSocket = [_]?TcpSocket{null} ** MAX_TCP_SOCKS;
var tcp_sock_count: usize = 0;

pub fn init() void {
    for (&tcp_socks) |*slot| slot.* = null;
    tcp_sock_count = 0;
}

pub fn findSock(fd: i32) ?*TcpSocket {
    for (&tcp_socks) |*slot| {
        if (slot.*) |*s| {
            if (s.fd == fd) return s;
        }
    }
    return null;
}

pub fn socket() !i32 {
    for (&tcp_socks, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = .{ .fd = @as(i32, @intCast(200 + i)) };
            tcp_sock_count += 1;
            return slot.*.?.fd;
        }
    }
    return error.NoMem;
}

pub fn passive_open(fd: i32, local_port: u16) TcpError!void {
    const s = findSock(fd) orelse return error.NotFound;
    if (s.state != .closed) return error.InvalidState;
    s.state = .listen;
    s.local_port = local_port;
}

pub fn active_open(fd: i32, remote_port: u16) TcpError!void {
    const s = findSock(fd) orelse return error.NotFound;
    if (s.state != .closed) return error.InvalidState;
    s.state = .syn_sent;
    s.remote_port = remote_port;
}

pub fn transition(fd: i32, event: TcpEvent) TcpError!void {
    const s = findSock(fd) orelse return error.NotFound;
    switch (s.state) {
        .closed => switch (event) {
            .passive_open => { s.state = .listen; },
            .active_open => { s.state = .syn_sent; },
            else => return error.InvalidState,
        },
        .listen => switch (event) {
            .recv_syn => { s.state = .syn_received; },
            .send_fin => { s.state = .closed; s.reset(); },
            else => return error.InvalidState,
        },
        .syn_sent => switch (event) {
            .recv_syn_ack => { s.state = .established; },
            .send_fin => { s.state = .fin_wait_1; },
            .timeout => { s.state = .closed; s.reset(); },
            else => return error.InvalidState,
        },
        .syn_received => switch (event) {
            .send_ack => { s.state = .established; },
            .send_fin => { s.state = .fin_wait_1; },
            else => return error.InvalidState,
        },
        .established => switch (event) {
            .send_fin => { s.state = .fin_wait_1; },
            .recv_fin => { s.state = .close_wait; },
            .send_data, .recv_data => {},
            else => return error.InvalidState,
        },
        .fin_wait_1 => switch (event) {
            .recv_fin_ack => { s.state = .fin_wait_2; },
            .recv_fin => { s.state = .closing; },
            .send_fin_ack => { s.state = .time_wait; },
            else => return error.InvalidState,
        },
        .fin_wait_2 => switch (event) {
            .send_fin => { s.state = .time_wait; },
            .recv_fin => { s.state = .time_wait; },
            else => return error.InvalidState,
        },
        .close_wait => switch (event) {
            .send_fin => { s.state = .last_ack; },
            .send_data, .recv_data => {},
            else => return error.InvalidState,
        },
        .last_ack => switch (event) {
            .recv_fin_ack => { s.state = .closed; s.reset(); },
            .timeout => { s.state = .closed; s.reset(); },
            else => return error.InvalidState,
        },
        .closing => switch (event) {
            .recv_fin_ack => { s.state = .time_wait; },
            .timeout => { s.state = .closed; s.reset(); },
            else => return error.InvalidState,
        },
        .time_wait => switch (event) {
            .timeout => { s.state = .closed; s.reset(); },
            else => return error.InvalidState,
        },
    }
}

pub fn send(fd: i32, data: []const u8) TcpError!usize {
    const s = findSock(fd) orelse return error.NotFound;
    if (s.state != .established) return error.NotConnected;
    const avail = RX_BUF_SIZE - s.tx_len;
    const n = @min(data.len, avail);
    if (n == 0) return error.BufferFull;
    @memcpy(s.tx_buf[s.tx_len..][0..n], data[0..n]);
    s.tx_len += n;
    return n;
}

pub fn recv(fd: i32, out: []u8) TcpError!usize {
    const s = findSock(fd) orelse return error.NotFound;
    if (s.state == .closed or s.state == .time_wait) return error.Closed;
    if (s.rx_len == 0) return error.BufferEmpty;
    const n = @min(out.len, s.rx_len);
    @memcpy(out[0..n], s.rx_buf[0..n]);
    var i: usize = n;
    while (i < s.rx_len) : (i += 1) {
        s.rx_buf[i - n] = s.rx_buf[i];
    }
    s.rx_len -= n;
    return n;
}

pub fn loopback_deliver(src_fd: i32, dst_fd: i32) TcpError!usize {
    const src = findSock(src_fd) orelse return error.NotFound;
    const dst = findSock(dst_fd) orelse return error.NotFound;
    if (src.tx_len == 0) return 0;
    const avail = RX_BUF_SIZE - dst.rx_len;
    const n = @min(src.tx_len, avail);
    if (n == 0) return error.BufferFull;
    @memcpy(dst.rx_buf[dst.rx_len..][0..n], src.tx_buf[0..n]);
    dst.rx_len += n;
    src.tx_len = 0;
    return n;
}

pub fn getState(fd: i32) TcpState {
    const s = findSock(fd) orelse return .closed;
    return s.state;
}

// ---- Hosted tests ----
test "tcp: passive open -> listen" {
    const fd = try socket();
    try passive_open(fd, 8080);
    try std.testing.expectEqual(TcpState.listen, getState(fd));
}

test "tcp: active open -> syn_sent -> established" {
    const fd = try socket();
    try active_open(fd, 80);
    try std.testing.expectEqual(TcpState.syn_sent, getState(fd));
    try transition(fd, .recv_syn_ack);
    try std.testing.expectEqual(TcpState.established, getState(fd));
}

test "tcp: full client/server handshake + data + close" {
    const srv = try socket();
    const cli = try socket();
    try passive_open(srv, 80);
    try active_open(cli, 80);
    try std.testing.expectEqual(TcpState.syn_sent, getState(cli));
    try transition(srv, .recv_syn);
    try std.testing.expectEqual(TcpState.syn_received, getState(srv));
    try transition(srv, .send_ack);
    try std.testing.expectEqual(TcpState.established, getState(srv));
    try transition(cli, .recv_syn_ack);
    try std.testing.expectEqual(TcpState.established, getState(cli));
    const msg = "HELLO from TCP\n";
    const sent = try send(cli, msg);
    try std.testing.expectEqual(msg.len, sent);
    const delivered = try loopback_deliver(cli, srv);
    try std.testing.expectEqual(msg.len, delivered);
    var buf: [32]u8 = undefined;
    const recvd = try recv(srv, &buf);
    try std.testing.expectEqual(msg.len, recvd);
    try std.testing.expectEqualStrings(msg, buf[0..recvd]);
    try transition(cli, .send_fin);
    try std.testing.expectEqual(TcpState.fin_wait_1, getState(cli));
    try transition(srv, .recv_fin);
    try std.testing.expectEqual(TcpState.close_wait, getState(srv));
    try transition(srv, .send_fin);
    try std.testing.expectEqual(TcpState.last_ack, getState(srv));
    try transition(cli, .recv_fin_ack);
    try std.testing.expectEqual(TcpState.fin_wait_2, getState(cli));
    try transition(cli, .send_fin);
    try std.testing.expectEqual(TcpState.time_wait, getState(cli));
    try transition(srv, .timeout);
    try std.testing.expectEqual(TcpState.closed, getState(srv));
    try transition(cli, .timeout);
    try std.testing.expectEqual(TcpState.closed, getState(cli));
}

test "tcp: invalid transition returns error" {
    const fd = try socket();
    try std.testing.expectError(error.InvalidState, transition(fd, .send_data));
    try std.testing.expectError(error.InvalidState, transition(fd, .recv_fin));
}

test "tcp: buffer full on send" {
    const fd = try socket();
    try active_open(fd, 80);
    try transition(fd, .recv_syn_ack);
    const data: [4096]u8 = [_]u8{'X'} ** 4096;
    const sent1 = try send(fd, &data);
    try std.testing.expectEqual(@as(usize, 4096), sent1);
    const y: [1]u8 = [_]u8{'Y'};
    try std.testing.expectError(error.BufferFull, send(fd, &y));
}

test "tcp: recv empty returns BufferEmpty" {
    const fd = try socket();
    try active_open(fd, 80);
    try transition(fd, .recv_syn_ack);
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.BufferEmpty, recv(fd, &buf));
}
