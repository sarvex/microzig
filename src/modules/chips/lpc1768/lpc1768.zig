const std = @import("std");
const micro = @import("microzig");
const chip = @import("registers.zig");
const regs = chip.registers;

pub usingnamespace chip;

pub const clock = struct {
    pub const Domain = enum {
        cpu,
    };
};

pub const clock_frequencies = .{
    .cpu = 100_000_000, // 100 Mhz
};

pub const PinTarget = enum(u2) {
    func00 = 0b00,
    func01 = 0b01,
    func10 = 0b10,
    func11 = 0b11,
};

pub fn parsePin(comptime spec: []const u8) type {
    const invalid_format_msg = "The given pin '" ++ spec ++ "' has an invalid format. Pins must follow the format \"P{Port}.{Pin}\" scheme.";
    if (spec[0] != 'P')
        @compileError(invalid_format_msg);

    const index = std.mem.indexOfScalar(u8, spec, '.') orelse @compileError(invalid_format_msg);

    const _port: comptime_int = std.fmt.parseInt(u3, spec[1..index], 10) catch @compileError(invalid_format_msg);
    const _pin: comptime_int = std.fmt.parseInt(u5, spec[index + 1 ..], 10) catch @compileError(invalid_format_msg);

    const sel_reg_name = std.fmt.comptimePrint("PINSEL{d}", .{(2 * _port + _pin / 16)});

    const _regs = struct {
        const name_suffix = std.fmt.comptimePrint("{d}", .{_port});

        const pinsel_reg = @field(regs.PINCONNECT, sel_reg_name);
        const pinsel_field = std.fmt.comptimePrint("P{d}_{d}", .{ _port, _pin });

        const dir = @field(regs.GPIO, "DIR" ++ name_suffix);
        const pin = @field(regs.GPIO, "PIN" ++ name_suffix);
        const set = @field(regs.GPIO, "SET" ++ name_suffix);
        const clr = @field(regs.GPIO, "CLR" ++ name_suffix);
        const mask = @field(regs.GPIO, "MASK" ++ name_suffix);
    };

    return struct {
        pub const port: u3 = _port;
        pub const pin: u5 = _pin;
        pub const regs = _regs;
        const gpio_mask: u32 = (1 << pin);

        pub const Targets = PinTarget;
    };
}

pub fn routePin(comptime pin: type, function: PinTarget) void {
    var val = pin.regs.pinsel_reg.read();
    @field(val, pin.regs.pinsel_field) = @enumToInt(function);
    pin.regs.pinsel_reg.write(val);
}

pub const gpio = struct {
    pub fn setOutput(comptime pin: type) void {
        pin.regs.dir.raw |= pin.gpio_mask;
    }
    pub fn setInput(comptime pin: type) void {
        pin.regs.dir.raw &= ~pin.gpio_mask;
    }

    pub fn read(comptime pin: type) micro.gpio.State {
        return if ((pin.regs.pin.raw & pin.gpio_mask) != 0)
            micro.gpio.State.high
        else
            micro.gpio.State.low;
    }

    pub fn write(comptime pin: type, state: micro.gpio.State) void {
        if (state == .high) {
            pin.regs.set.raw = pin.gpio_mask;
        } else {
            pin.regs.clr.raw = pin.gpio_mask;
        }
    }
};

pub var uart0: Uart(0) = .{};
pub var uart1: Uart(1) = .{};
pub var uart2: Uart(2) = .{};
pub var uart3: Uart(3) = .{};

pub fn Uart(comptime index: comptime_int) type {
    return struct {
        const Self = @This();
        const Intf = micro.interface.Uart;

        pub const registers = switch (index) {
            0 => regs.UART0,
            1 => regs.UART1,
            2 => regs.UART2,
            3 => regs.UART3,
            else => @compileError("LPC1768 has 4 UARTs available."),
        };

        send_transfer: ?*Intf.SendTransfer = null,
        receive_transfer: ?*Intf.ReceiveTransfer = null,

        pub fn init(uart: *Self, comptime pins: micro.uart.Pins) !void {
            if (pins.tx != null or pins.rx != null)
                @compileError("TODO: custom pins are not currently supported");

            switch (index) {
                0 => {
                    regs.SYSCON.PCONP.modify(.{ .PCUART0 = 1 });
                    regs.SYSCON.PCLKSEL0.modify(.{ .PCLK_UART0 = @enumToInt(uart.CClkDiv.four) });
                },
                1 => {
                    regs.SYSCON.PCONP.modify(.{ .PCUART1 = 1 });
                    regs.SYSCON.PCLKSEL0.modify(.{ .PCLK_UART1 = @enumToInt(uart.CClkDiv.four) });
                },
                2 => {
                    regs.SYSCON.PCONP.modify(.{ .PCUART2 = 1 });
                    regs.SYSCON.PCLKSEL1.modify(.{ .PCLK_UART2 = @enumToInt(uart.CClkDiv.four) });
                },
                3 => {
                    regs.SYSCON.PCONP.modify(.{ .PCUART3 = 1 });
                    regs.SYSCON.PCLKSEL1.modify(.{ .PCLK_UART3 = @enumToInt(uart.CClkDiv.four) });
                },
                else => unreachable,
            }
        }

        // pub const CClkDiv = enum(u2) {
        //     four = 0,
        //     one = 1,
        //     two = 2,
        //     eight = 3,
        // };

        pub fn configure(uart: Self, config: Intf.Config) Intf.ConfigError!void {
            _ = uart;

            registers.LCR.modify(.{
                // 8N1
                .WLS = switch (config.data_bits) {
                    .five => @as(u2, 0),
                    .six => @as(u2, 1),
                    .seven => @as(u2, 2),
                    .eight => @as(u2, 3),
                },
                .SBS = switch (config.stop_bits) {
                    .one => @as(u1, 0),
                    .two => @as(u1, 1),
                    else => return error.StopBitsNotSupported,
                },
                .PE = if (config.parity != .none) @as(u1, 1) else @as(u1, 0),
                .PS = switch (config.parity) {
                    .none => @as(u2, 0),
                    .odd => @as(u2, 0),
                    .even => @as(u2, 1),
                    .mark => @as(u2, 2),
                    .space => @as(u2, 3),
                },
                .BC = 0,
                .DLAB = 1,
            });

            // TODO: UARTN_FIFOS_ARE_DISA is not available in all uarts
            //UARTn.FCR.modify(.{ .FIFOEN = .UARTN_FIFOS_ARE_DISA });

            micro.debug.writer().print("clock: {} baud: {?} ", .{
                micro.clock.get().cpu,
                config.baud_rate,
            }) catch {};

            if (config.baud_rate) |baud_rate| {
                const pclk = micro.clock.get().cpu / 4;
                const divider = (pclk / (16 * baud_rate));

                const regval = std.math.cast(u16, divider) orelse return error.BaudRateNotSupported;

                registers.DLL.modify(.{ .DLLSB = @truncate(u8, regval >> 0x00) });
                registers.DLM.modify(.{ .DLMSB = @truncate(u8, regval >> 0x08) });

                registers.LCR.modify(.{ .DLAB = 0 });
            } else {
                // TODO: Implement auto-bauding.
                return error.AutoBaudNotSupported;
            }
        }

        pub fn send(uart: *Self, transfer: *Intf.SendTransfer) Intf.BeginSendError!void {
            if (uart.send_transfer != null)
                return error.InProgress;

            transfer.bytes_transferred = 0;
            transfer.@"error" = null;
            uart.send_transfer = transfer;
        }

        pub fn receive(uart: *Self, transfer: *Intf.ReceiveTransfer) Intf.BeginReceiveError!void {
            if (uart.receive_transfer != null)
                return error.InProgress;

            transfer.bytes_transferred = 0;
            transfer.@"error" = null;
            uart.receive_transfer = transfer;
        }

        pub fn tick(uart: *Self) void {
            if (uart.send_transfer) |transfer| {
                if (uart.canWrite()) {
                    uart.tx(transfer.data[transfer.bytes_transferred]);
                    transfer.bytes_transferred += 1;

                    if (transfer.bytes_transferred >= transfer.data.len) {
                        transfer.done = true;
                        uart.send_transfer = null;
                    }
                }
            }

            if (uart.receive_transfer) |transfer| {
                if (uart.canRead()) {
                    transfer.data[transfer.bytes_transferred] = uart.rx();
                    transfer.bytes_transferred += 1;

                    if (transfer.bytes_transferred >= transfer.data.len) {
                        transfer.done = true;
                        uart.receive_transfer = null;
                    }
                }
            }
        }

        pub fn canWrite(self: Self) bool {
            _ = self;
            return (registers.LSR.read().THRE == 1);
        }

        pub fn tx(self: Self, ch: u8) void {
            while (!self.canWrite()) {} // Wait for Previous transmission
            registers.THR.raw = ch; // Load the data to be transmitted
        }

        pub fn canRead(self: Self) bool {
            _ = self;
            return (registers.LSR.read().RDR == 1);
        }

        pub fn rx(self: Self) u8 {
            while (!self.canRead()) {} // Wait till the data is received
            return registers.RBR.read().RBR; // Read received data
        }

        comptime {
            micro.interface.Uart.Interface.verify(@This());
        }
    };
}
