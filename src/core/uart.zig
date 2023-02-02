const std = @import("std");
const micro = @import("microzig.zig");
const chip = @import("chip");

pub fn Uart(comptime index: usize, comptime pins: Pins) type {
    const SystemUart = chip.Uart(index, pins);
    return struct {
        const Self = @This();

        internal: SystemUart,

        /// Initializes the UART with the given config and returns a handle to the uart.
        pub fn init(config: Config) InitError!Self {
            micro.clock.ensure();
            return Self{
                .internal = try SystemUart.init(config),
            };
        }

        /// If the UART is already initialized, try to return a handle to it,
        /// else initialize with the given config.
        pub fn getOrInit(config: Config) InitError!Self {
            if (!@hasDecl(SystemUart, "getOrInit")) {
                // fallback to reinitializing the UART
                return init(config);
            }
            return Self{
                .internal = try SystemUart.getOrInit(config),
            };
        }

        pub fn canRead(self: Self) bool {
            return self.internal.canRead();
        }

        pub fn canWrite(self: Self) bool {
            return self.internal.canWrite();
        }

        pub fn reader(self: Self) Reader {
            return Reader{ .context = self };
        }

        pub fn writer(self: Self) Writer {
            return Writer{ .context = self };
        }

        pub const Reader = std.io.Reader(Self, ReadError, readSome);
        pub const Writer = std.io.Writer(Self, WriteError, writeSome);

        fn readSome(self: Self, buffer: []u8) ReadError!usize {
            for (buffer) |*c| {
                c.* = self.internal.rx();
            }
            return buffer.len;
        }
        fn writeSome(self: Self, buffer: []const u8) WriteError!usize {
            for (buffer) |c| {
                self.internal.tx(c);
            }
            return buffer.len;
        }
    };
}

/// The pin configuration. This is used to optionally configure specific pins to be used with the chosen UART.
/// This makes sense only with microcontrollers supporting multiple pins for a UART peripheral.
pub const Pins = struct {
    tx: ?type = null,
    rx: ?type = null,
};
