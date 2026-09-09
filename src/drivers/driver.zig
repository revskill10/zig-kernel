// drivers/driver — Device Driver Model (analog: drivers/base + bus_type)
// Clean: Bus=Framework, Device=Entity, Driver=Adapter (DIP via vtable)
const std = @import("std");
const printk = @import("../lib/printk.zig");

pub const BusType = enum { pci, platform, usb };

pub const DeviceOps = struct {
    probe: ?*const fn (*Device) anyerror!void = null,
    remove: ?*const fn (*Device) void = null,
    suspend_fn: ?*const fn (*Device) void = null,
};

pub const Device = struct {
    name: []const u8,
    bus: BusType,
    driver: ?*Driver = null,
    // simulated MMIO base (analog to BAR)
    mmio_base: usize = 0,
    irq: u32 = 0,
    data: ?*anyopaque = null,
};

pub const Driver = struct {
    name: []const u8,
    bus: BusType,
    // vtable — DIP: core depends on Driver interface, not concrete e1000
    probe: *const fn (*Device) anyerror!void,
    remove: ?*const fn (*Device) void = null,
    ops: ?*const anyopaque = null, // cast to NetOps / CharOps etc.
};

const MAX_DEVICES: usize = 16;
const MAX_DRIVERS: usize = 16;
var devices: [MAX_DEVICES]?Device = [_]?Device{null} ** MAX_DEVICES;
var drivers: [MAX_DRIVERS]?Driver = [_]?Driver{null} ** MAX_DRIVERS;
var device_count: usize = 0;
var driver_count: usize = 0;

pub fn init() void {
    printk.printk(.info, "drivers: bus model ready (pci/platform/usb), device/driver registry ready", .{});
}

pub fn registerDriver(drv: Driver) !void {
    if (driver_count >= MAX_DRIVERS) return error.NoMem;
    drivers[driver_count] = drv;
    driver_count += 1;
    printk.printk(.info, "drivers: registered driver '{s}' on bus {s}", .{ drv.name, @tagName(drv.bus) });
    // Probe already-present devices (LKM hotplug analog)
    for (devices[0..device_count]) |*dev_opt| if (dev_opt.*) |*dev| if (dev.bus == drv.bus and dev.driver == null) {
        try drv.probe(dev);
        dev.driver = &drivers[driver_count - 1].?;
    };
}

pub fn registerDevice(dev: Device) !void {
    if (device_count >= MAX_DEVICES) return error.NoMem;
    devices[device_count] = dev;
    device_count += 1;
    const d = &devices[device_count - 1].?;
    printk.printk(.info, "drivers: device '{s}' appeared on bus {s} irq={d}", .{ d.name, @tagName(d.bus), d.irq });
    // Try to bind to existing driver (analog to driver_probe)
    for (drivers[0..driver_count]) |*drv_opt| if (drv_opt.*) |*drv| if (drv.bus == d.bus) {
        drv.probe(d) catch |e| {
            printk.printk(.warn, "drivers: probe '{s}'→'{s}' failed: {any}", .{ drv.name, d.name, e });
            continue;
        };
        d.driver = drv;
        printk.printk(.info, "drivers: bound '{s}' → driver '{s}'", .{ d.name, drv.name });
        break;
    };
}

pub fn listDevices() []?Device { return devices[0..device_count]; }
pub fn listDrivers() []?Driver { return drivers[0..driver_count]; }
