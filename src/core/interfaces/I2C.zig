//!
//! A runtime interface for I²C/TWI/SMBus drivers.
//!

const std = @import("std");
const interface = @import("interface.zig");

const I2C = @This();

instance: *anyopaque,
vtable: *const VTable,

pub const ConfigError = error{InProgress};
pub fn configure(i2c: I2C, config: Config) ConfigError!void {
    return i2c.vtable.configure(i2c.instance, config);
}

pub const StartError = error{InProgress};
pub fn start(i2c: I2C, transfer: *Transfer) StartError!void {
    return i2c.vtable.start(i2c.instance, transfer);
}

pub const TransferQueue = std.TailQueue(struct {});
pub const Transfer = struct {
    /// internal queuing of the data structure
    node: TransferQueue.Node = .{ .data = .{} },
    done: bool = false,

    next: ?*Transfer = null,

    /// The device that will be interfaced.
    device_address: u7,

    /// Either a read or a write buffer, determining the direction
    /// of the operation.
    data: TransferMode,

    pub fn isCompleted(transfer: *const volatile Transfer) bool {
        // needs volatile read as the transfer might be written from an interrupt
        return transfer.done;
    }
};

pub const TransferMode = union(enum) {
    read: []u8,
    write: []const u8,
};

pub const Config = struct {
    frequency: u32 = 100_000,
};

pub const Interface = interface.Interface(struct {
    configure: fn (interface.Self, config: Config) ConfigError!void,
    start: fn (interface.Self, transfer: *Transfer) StartError!void,
});

pub const VTable = Interface.VTable;

comptime {
    Interface.verify(@This());
}

const TestImpl = struct {
    const Self = @This();

    pub fn configure(impl: TestImpl, config: Config) ConfigError!void {
        _ = impl;
        _ = config;
    }

    pub fn start(impl: TestImpl, transfer: *Transfer) StartError!void {
        _ = impl;
        _ = transfer;
    }

    comptime {
        Interface.verify(@This());
    }
};

test "verifyInterface" {
    Interface.verify(TestImpl);
}

test "VTable.get" {
    _ = Interface.constructVTable(TestImpl);
}

test "Interface" {
    _ = I2C.configure;
    _ = I2C.start;
}
