//!
//! A runtime interface for GPIO drivers.
//!

const std = @import("std");
const interface = @import("interface.zig");

const GPIO = @This();

/// Supports up to 256 gpio ports with 256 pins each.
pub const Pin = packed struct(u16) {
    port: u8,
    index: u8,
};

instance: *anyopaque,
vtable: *const VTable,

pub fn new(ptr: anytype) GPIO {
    const info = @typeInfo(@TypeOf(ptr)).Pointer; // pass in single pointer
    return GPIO{
        .instance = ptr,
        .vtable = Interface.constructVTable(info.child),
    };
}

pub const ParsePinError = error{UnknownPin};

/// Parses `spec` to convert a pin name into a concrete pin instance.
/// This is a runtime variant of the `<GpioDriver>.pin` function that
/// will use a comptime specification instead.
pub fn parsePin(gpio: GPIO, spec: []const u8) ParsePinError!Pin {
    return gpio.vtable.pin(gpio.instance, spec);
}

pub const ConfigError = error{ UnsupportedDirection, UnsupportedPull };
pub fn configure(gpio: GPIO, pin: Pin, config: Config) ConfigError!void {
    return gpio.vtable.configure(gpio.instance, pin, config);
}

pub fn read(gpio: GPIO, pin: Pin) State {
    return gpio.vtable.read(gpio.instance, pin);
}

pub fn write(gpio: GPIO, pin: Pin, state: State) void {
    return gpio.vtable.write(gpio.instance, pin, state);
}

pub const State = enum(u1) {
    low = 0,
    high = 1,
};

pub const Config = struct {
    direction: Direction,
    pull: PullDirection = .none,
};

pub const Direction = enum {
    input,
    push_pull,
    open_collector,
};

pub const PullDirection = enum {
    none,
    up,
    down,
};

// pub const Interface = interface.Interface(struct {
//     configure: fn (interface.Self, config: Config) ConfigError!void,
//     start: fn (interface.Self, transfer: *Transfer) StartError!void,
// });

// pub const VTable = Interface.VTable;

// comptime {
//     Interface.verify(@This());
// }

// const TestImpl = struct {
//     const Self = @This();

//     // pub fn configure(impl: TestImpl, config: Config) ConfigError!void {
//     //     _ = impl;
//     //     _ = config;
//     // }

//     // pub fn start(impl: TestImpl, transfer: *Transfer) StartError!void {
//     //     _ = impl;
//     //     _ = transfer;
//     // }

//     comptime {
//         Interface.verify(@This());
//     }
// };

// test "verifyInterface" {
//     Interface.verify(TestImpl);
// }

// test "VTable.get" {
//     _ = Interface.constructVTable(TestImpl);
// }

// test "Interface" {
//     _ = GPIO.configure;
//     _ = GPIO.start;
// }
