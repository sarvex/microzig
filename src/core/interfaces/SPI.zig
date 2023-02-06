//!
//! A runtime interface for SPI drivers.
//!

const std = @import("std");
const interface = @import("interface.zig");

const SPI = @This();

instance: *anyopaque,
vtable: *const VTable,

pub fn new(ptr: anytype) SPI {
    const info = @typeInfo(@TypeOf(ptr)).Pointer; // pass in single pointer
    return SPI{
        .instance = ptr,
        .vtable = Interface.constructVTable(info.child),
    };
}

pub const ConfigError = error{InProgress};
pub fn configure(spi: SPI, config: Config) ConfigError!void {
    return spi.vtable.configure(spi.instance, config);
}

pub const StartError = error{InProgress};
pub fn start(spi: SPI, transfer: *Transfer) StartError!void {
    return spi.vtable.start(spi.instance, transfer);
}

pub const TransferQueue = std.TailQueue(struct {});
pub const Transfer = struct {
    /// internal queuing of the data structure
    node: TransferQueue.Node = .{ .data = .{} },
    done: bool = false,

    next: ?*Transfer = null,

    /// The buffer that contains the data that should be sent.
    data_out: ?[]const u8,

    /// The buffer that will receive the data that was read.
    data_in: ?[]u8,

    pub fn isCompleted(transfer: *const volatile Transfer) bool {
        // needs volatile read as the transfer might be written from an interrupt
        return transfer.done;
    }
};

pub const Config = struct {
    frequency: u32 = 100_000,
    mode: Mode,
};

pub const Mode = packed struct(u2) {
    clock_idle_polarity: enum(u1) { low = 0, high = 1 }, // CPOL
    clock_data_valid_edge: enum(u1) { leading = 0, trailing = 1 }, // CPHA

    /// CPOL=0, CPHA=0
    pub const mode0 = Mode{ .clock_idle_polarity = .low, .clock_data_valid_edge = .leading };

    /// CPOL=0, CPHA=1
    pub const mode1 = Mode{ .clock_idle_polarity = .low, .clock_data_valid_edge = .trailing };

    /// CPOL=1, CPHA=0
    pub const mode2 = Mode{ .clock_idle_polarity = .high, .clock_data_valid_edge = .leading };

    /// CPOL=1, CPHA=1
    pub const mode3 = Mode{ .clock_idle_polarity = .high, .clock_data_valid_edge = .trailing };
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
    _ = SPI.configure;
    _ = SPI.start;
}
