const std = @import("std");
const micro = @import("microzig");

pub usingnamespace @import("registers.zig");
const regz = @import("registers.zig").registers;

pub const cpu = micro.cpu;
const Port = enum(u8) {
    B = 1,
    C = 2,
    D = 3,
};

pub const clock = struct {
    pub const Domain = enum {
        cpu,
    };
};

pub fn parsePin(comptime spec: []const u8) type {
    const invalid_format_msg = "The given pin '" ++ spec ++ "' has an invalid format. Pins must follow the format \"P{Port}{Pin}\" scheme.";

    if (spec.len != 3)
        @compileError(invalid_format_msg);
    if (spec[0] != 'P')
        @compileError(invalid_format_msg);

    return struct {
        pub const port: Port = std.meta.stringToEnum(Port, spec[1..2]) orelse @compileError(invalid_format_msg);
        pub const pin: u3 = std.fmt.parseInt(u3, spec[2..3], 10) catch @compileError(invalid_format_msg);
    };
}

pub const gpio = struct {
    fn regs(comptime desc: type) type {
        return struct {
            // io address
            const pin_addr: u5 = 3 * @enumToInt(desc.port) + 0x00;
            const dir_addr: u5 = 3 * @enumToInt(desc.port) + 0x01;
            const port_addr: u5 = 3 * @enumToInt(desc.port) + 0x02;

            // ram mapping
            const pin = @intToPtr(*volatile u8, 0x20 + @as(usize, pin_addr));
            const dir = @intToPtr(*volatile u8, 0x20 + @as(usize, dir_addr));
            const port = @intToPtr(*volatile u8, 0x20 + @as(usize, port_addr));
        };
    }

    pub fn setOutput(comptime pin: type) void {
        cpu.sbi(regs(pin).dir_addr, pin.pin);
    }

    pub fn setInput(comptime pin: type) void {
        cpu.cbi(regs(pin).dir_addr, pin.pin);
    }

    pub fn read(comptime pin: type) micro.gpio.State {
        return if ((regs(pin).pin.* & (1 << pin.pin)) != 0)
            .high
        else
            .low;
    }

    pub fn write(comptime pin: type, state: micro.gpio.State) void {
        if (state == .high) {
            cpu.sbi(regs(pin).port_addr, pin.pin);
        } else {
            cpu.cbi(regs(pin).port_addr, pin.pin);
        }
    }

    pub fn toggle(comptime pin: type) void {
        cpu.sbi(regs(pin).pin_addr, pin.pin);
    }
};

pub var uart0: Uart = .{};

pub const Uart = struct {
    const Intf = micro.interface.Uart;

    send_transfer: ?*Intf.SendTransfer = null,
    receive_transfer: ?*Intf.ReceiveTransfer = null,

    fn computeDivider(baud_rate: u32) !u12 {
        const pclk = comptime micro.clock.get().cpu;
        const divider = ((pclk + (8 * baud_rate)) / (16 * baud_rate)) - 1;

        return std.math.cast(u12, divider) orelse return error.BaudRateNotSupported;
    }

    fn computeBaudRate(divider: u12) u32 {
        return micro.clock.get().cpu / (16 * @as(u32, divider) + 1);
    }

    pub fn configure(uart: Uart, config: Intf.Config) Intf.ConfigError!void {
        _ = uart;

        const baud_rate = config.baud_rate orelse return error.AutoBaudNotSupported;

        if (config.control_flow != .none)
            return error.ControlFlowNotSupported;

        const ucsz: u3 = switch (config.data_bits) {
            .five => 0b000,
            .six => 0b001,
            .seven => 0b010,
            .eight => 0b011,
        };

        const upm: u2 = switch (config.parity) {
            .none => @as(u2, 0b00), // none
            .even => @as(u2, 0b10), // even
            .odd => @as(u2, 0b11), // odd
            else => return error.ParityNotSupported,
        };

        const usbs: u1 = switch (config.stop_bits) {
            .one => 0b0,
            .two => 0b1,
            .one_point_five => return error.StopBitsNotSupported,
        };

        const umsel: u2 = 0b00; // Asynchronous USART

        // baud is computed like this:
        //             f(osc)
        // BAUD = ----------------
        //        16 * (UBRRn + 1)

        const ubrr_val = try computeDivider(baud_rate);

        regz.USART0.UCSR0A.modify(.{
            .MPCM0 = 0,
            .U2X0 = 0,
        });
        regz.USART0.UCSR0B.write(.{
            .TXB80 = 0, // we don't care about these btw
            .RXB80 = 0, // we don't care about these btw
            .UCSZ02 = @truncate(u1, (ucsz & 0x04) >> 2),
            .TXEN0 = 1,
            .RXEN0 = 1,
            .UDRIE0 = 0, // no interrupts
            .TXCIE0 = 0, // no interrupts
            .RXCIE0 = 0, // no interrupts
        });
        regz.USART0.UCSR0C.write(.{
            .UCPOL0 = 0, // async mode
            .UCSZ0 = @truncate(u2, (ucsz & 0x03) >> 0),
            .USBS0 = usbs,
            .UPM0 = upm,
            .UMSEL0 = umsel,
        });

        regz.USART0.UBRR0.modify(ubrr_val);
    }

    pub fn send(uart: *Uart, transfer: *Intf.SendTransfer) Intf.BeginSendError!void {
        if (uart.send_transfer != null)
            return error.InProgress;

        transfer.bytes_transferred = 0;
        transfer.@"error" = null;
        uart.send_transfer = transfer;
    }

    pub fn receive(uart: *Uart, transfer: *Intf.ReceiveTransfer) Intf.BeginReceiveError!void {
        if (uart.receive_transfer != null)
            return error.InProgress;

        transfer.bytes_transferred = 0;
        transfer.@"error" = null;
        uart.receive_transfer = transfer;
    }

    pub fn tick(uart: *Uart) void {
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

    pub fn canWrite(uart: Uart) bool {
        _ = uart;
        return (regz.USART0.UCSR0A.read().UDRE0 == 1);
    }

    pub fn tx(uart: Uart, ch: u8) void {
        while (!uart.canWrite()) {} // Wait for Previous transmission
        regz.USART0.UDR0.* = ch; // Load the data to be transmitted
    }

    pub fn canRead(uart: Uart) bool {
        _ = uart;
        return (regz.USART0.UCSR0A.read().RXC0 == 1);
    }

    pub fn rx(uart: Uart) u8 {
        while (!uart.canRead()) {} // Wait till the data is received
        return regz.USART0.UDR0.*; // Read received data
    }

    comptime {
        micro.interface.Uart.Interface.verify(@This());
    }
};

// pub fn Uart(comptime index: usize, comptime pins: micro.uart.Pins) type {
//     if (index != 0) @compileError("Atmega328p only has a single uart!");
//     if (pins.tx != null or pins.rx != null)
//         @compileError("Atmega328p has fixed pins for uart!");

//     return struct {

//     };
// }
