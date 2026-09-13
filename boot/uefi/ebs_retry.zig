// boot/uefi/ebs_retry — production ExitBootServices retry policy.
// Linked from boot/uefi/main.zig (sibling import). Host-testable: no UEFI
// types. Zig 0.16 boot_services.zig documents that after the first
// unsuccessful ExitBootServices, only GetMemoryMap remains permitted.
// Allocate/grow/free and getMemoryMapInfo are legal only before that
// boundary. Post-boundary errors halt; they must not return to firmware.

const std = @import("std");

pub const Boundary = enum { pre_ebs, post_ebs };

pub const Call = enum {
    get_memory_map_info,
    allocate_pool,
    free_pool,
    get_memory_map,
    exit_boot_services,
    return_to_firmware,
    halt,
};

/// Firmware calls (and returning to firmware) allowed in this phase.
pub fn legal(boundary: Boundary, call: Call) bool {
    return switch (call) {
        .halt => true,
        .return_to_firmware => boundary == .pre_ebs,
        .get_memory_map, .exit_boot_services => true,
        .get_memory_map_info, .allocate_pool, .free_pool => boundary == .pre_ebs,
    };
}

pub const MapAction = enum { grow, fail_return, fail_halt };

/// Classify a GetMemoryMap failure. Buffer growth is legal only before the
/// first EBS attempt; after the boundary every map error fails closed.
pub fn onGetMemoryMapError(boundary: Boundary, err: anyerror, can_grow: bool) MapAction {
    return switch (boundary) {
        .pre_ebs => if (err == error.BufferTooSmall and can_grow) .grow else .fail_return,
        .post_ebs => .fail_halt,
    };
}

pub const EbsAction = enum { retry_retained, fail_halt };

/// Classify an ExitBootServices failure. Only InvalidParameter is a stale
/// map key and may retry (GetMemoryMap into the retained buffer). Any other
/// status fails closed and must not be treated as a stale-key retry.
pub fn onExitBootServicesError(err: anyerror, retries_left: bool) EbsAction {
    if (err == error.InvalidParameter and retries_left) return .retry_retained;
    return .fail_halt;
}

pub const MapGet = enum { ok, buffer_too_small, other };
pub const EbsGet = enum { ok, invalid_parameter, other };

/// Scripted firmware replies for the hosted trace driver.
pub const Script = struct {
    /// Pre-EBS GetMemoryMap BufferTooSmall replies before a successful fill.
    pre_too_small: u32 = 0,
    /// ExitBootServices results in call order. Driver stops on success/halt.
    ebs: []const EbsGet,
    /// GetMemoryMap result on the post-EBS retained-buffer path.
    post_map: MapGet = .ok,
    max_retries: u32 = 3,
    max_growths: u32 = 3,
};

pub const Outcome = enum { handoff, halt, returned };

pub const Trace = struct {
    calls: [32]Call = undefined,
    len: usize = 0,
    outcome: Outcome = .halt,
    illegal: bool = false,
    boundary: Boundary = .pre_ebs,

    fn rec(self: *Trace, call: Call) void {
        if (!legal(self.boundary, call)) self.illegal = true;
        if (self.len < self.calls.len) {
            self.calls[self.len] = call;
            self.len += 1;
        }
    }

    pub fn slice(self: *const Trace) []const Call {
        return self.calls[0..self.len];
    }
};

/// Drive the same decision table the UEFI loader consults, against a
/// scripted fake firmware. Records every Boot Service analogue so tests
/// can assert the legal sequence and reject post-EBS allocate/free/return.
pub fn simulate(script: Script) Trace {
    var t = Trace{};

    t.rec(.get_memory_map_info);
    t.rec(.allocate_pool);
    var growth: u32 = 0;
    var remaining_small = script.pre_too_small;
    while (remaining_small > 0) {
        t.rec(.get_memory_map);
        const action = onGetMemoryMapError(.pre_ebs, error.BufferTooSmall, growth < script.max_growths);
        t.rec(.free_pool);
        switch (action) {
            .grow => {
                growth += 1;
                remaining_small -= 1;
                t.rec(.allocate_pool);
            },
            .fail_return => {
                t.rec(.return_to_firmware);
                t.outcome = .returned;
                return t;
            },
            .fail_halt => {
                t.rec(.halt);
                t.outcome = .halt;
                return t;
            },
        }
    }
    t.rec(.get_memory_map);

    var attempt: u32 = 0;
    var ebs_i: usize = 0;
    while (attempt < script.max_retries) {
        if (ebs_i >= script.ebs.len) break;
        t.rec(.exit_boot_services);
        const ebs = script.ebs[ebs_i];
        ebs_i += 1;
        switch (ebs) {
            .ok => {
                t.outcome = .handoff;
                return t;
            },
            .invalid_parameter, .other => {
                t.boundary = .post_ebs;
                const err: anyerror = if (ebs == .invalid_parameter)
                    error.InvalidParameter
                else
                    error.Unexpected;
                switch (onExitBootServicesError(err, attempt + 1 < script.max_retries)) {
                    .retry_retained => {
                        attempt += 1;
                        t.rec(.get_memory_map);
                        switch (script.post_map) {
                            .ok => {},
                            .buffer_too_small, .other => {
                                const map_err: anyerror = if (script.post_map == .buffer_too_small)
                                    error.BufferTooSmall
                                else
                                    error.Unexpected;
                                switch (onGetMemoryMapError(.post_ebs, map_err, true)) {
                                    .fail_halt => {
                                        t.rec(.halt);
                                        t.outcome = .halt;
                                        return t;
                                    },
                                    .grow, .fail_return => {
                                        // A grow/return disposition after EBS is a
                                        // policy bug; mark illegal and halt.
                                        t.illegal = true;
                                        t.rec(.halt);
                                        t.outcome = .halt;
                                        return t;
                                    },
                                }
                            },
                        }
                    },
                    .fail_halt => {
                        t.rec(.halt);
                        t.outcome = .halt;
                        return t;
                    },
                }
            },
        }
    }
    t.rec(.halt);
    t.outcome = .halt;
    return t;
}

fn expectSeq(t: Trace, expected: []const Call) !void {
    try std.testing.expectEqual(expected.len, t.len);
    try std.testing.expectEqualSlices(Call, expected, t.slice());
}

test "ebs_retry: stale-key path is GetMemoryMap, EBS(InvalidParameter), GetMemoryMap, EBS" {
    const ebs = [_]EbsGet{ .invalid_parameter, .ok };
    const t = simulate(.{ .ebs = &ebs });
    try std.testing.expect(!t.illegal);
    try std.testing.expectEqual(Outcome.handoff, t.outcome);
    try expectSeq(t, &.{
        .get_memory_map_info,
        .allocate_pool,
        .get_memory_map,
        .exit_boot_services,
        .get_memory_map,
        .exit_boot_services,
    });
    // Nothing between the two EBS calls except GetMemoryMap.
    try std.testing.expectEqual(Call.get_memory_map, t.calls[4]);
    try std.testing.expect(t.calls[4] != .free_pool);
    try std.testing.expect(t.calls[4] != .allocate_pool);
    try std.testing.expect(t.calls[4] != .get_memory_map_info);
    try std.testing.expect(t.calls[4] != .return_to_firmware);
}

test "ebs_retry: post-EBS BufferTooSmall fails closed without allocation or return" {
    const ebs = [_]EbsGet{.invalid_parameter};
    const t = simulate(.{ .ebs = &ebs, .post_map = .buffer_too_small });
    try std.testing.expect(!t.illegal);
    try std.testing.expectEqual(Outcome.halt, t.outcome);
    try expectSeq(t, &.{
        .get_memory_map_info,
        .allocate_pool,
        .get_memory_map,
        .exit_boot_services,
        .get_memory_map,
        .halt,
    });
    for (t.slice()) |c| {
        try std.testing.expect(c != .return_to_firmware);
    }
    // The only allocate/free are the pre-EBS acquire pair.
    var allocs: usize = 0;
    var frees: usize = 0;
    for (t.slice()) |c| {
        if (c == .allocate_pool) allocs += 1;
        if (c == .free_pool) frees += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), allocs);
    try std.testing.expectEqual(@as(usize, 0), frees);
}

test "ebs_retry: unexpected EBS error does not take the stale-key retry" {
    const ebs = [_]EbsGet{.other};
    const t = simulate(.{ .ebs = &ebs });
    try std.testing.expect(!t.illegal);
    try std.testing.expectEqual(Outcome.halt, t.outcome);
    try expectSeq(t, &.{
        .get_memory_map_info,
        .allocate_pool,
        .get_memory_map,
        .exit_boot_services,
        .halt,
    });
}

test "ebs_retry: pre-EBS BufferTooSmall may freePool and grow" {
    const ebs = [_]EbsGet{.ok};
    const t = simulate(.{ .pre_too_small = 1, .ebs = &ebs });
    try std.testing.expect(!t.illegal);
    try std.testing.expectEqual(Outcome.handoff, t.outcome);
    try expectSeq(t, &.{
        .get_memory_map_info,
        .allocate_pool,
        .get_memory_map,
        .free_pool,
        .allocate_pool,
        .get_memory_map,
        .exit_boot_services,
    });
}

test "ebs_retry: exhausted stale-key retries halt instead of returning" {
    const ebs = [_]EbsGet{ .invalid_parameter, .invalid_parameter, .invalid_parameter };
    const t = simulate(.{ .ebs = &ebs, .max_retries = 3 });
    try std.testing.expect(!t.illegal);
    try std.testing.expectEqual(Outcome.halt, t.outcome);
    try expectSeq(t, &.{
        .get_memory_map_info,
        .allocate_pool,
        .get_memory_map,
        .exit_boot_services,
        .get_memory_map,
        .exit_boot_services,
        .get_memory_map,
        .exit_boot_services,
        .halt,
    });
}

test "ebs_retry: post-EBS allocate/free/info/return are illegal" {
    try std.testing.expect(!legal(.post_ebs, .return_to_firmware));
    try std.testing.expect(!legal(.post_ebs, .free_pool));
    try std.testing.expect(!legal(.post_ebs, .allocate_pool));
    try std.testing.expect(!legal(.post_ebs, .get_memory_map_info));
    try std.testing.expect(legal(.post_ebs, .get_memory_map));
    try std.testing.expect(legal(.post_ebs, .exit_boot_services));
    try std.testing.expect(legal(.post_ebs, .halt));
    try std.testing.expect(legal(.pre_ebs, .return_to_firmware));
    try std.testing.expect(legal(.pre_ebs, .free_pool));
    try std.testing.expect(legal(.pre_ebs, .allocate_pool));
    try std.testing.expect(legal(.pre_ebs, .get_memory_map_info));
}

test "ebs_retry: onExitBootServicesError distinguishes stale-key from unexpected" {
    try std.testing.expectEqual(EbsAction.retry_retained, onExitBootServicesError(error.InvalidParameter, true));
    try std.testing.expectEqual(EbsAction.fail_halt, onExitBootServicesError(error.InvalidParameter, false));
    try std.testing.expectEqual(EbsAction.fail_halt, onExitBootServicesError(error.Unexpected, true));
}

test "ebs_retry: onGetMemoryMapError refuses post-boundary growth" {
    try std.testing.expectEqual(MapAction.grow, onGetMemoryMapError(.pre_ebs, error.BufferTooSmall, true));
    try std.testing.expectEqual(MapAction.fail_return, onGetMemoryMapError(.pre_ebs, error.BufferTooSmall, false));
    try std.testing.expectEqual(MapAction.fail_return, onGetMemoryMapError(.pre_ebs, error.InvalidParameter, true));
    try std.testing.expectEqual(MapAction.fail_halt, onGetMemoryMapError(.post_ebs, error.BufferTooSmall, true));
    try std.testing.expectEqual(MapAction.fail_halt, onGetMemoryMapError(.post_ebs, error.Unexpected, true));
}
