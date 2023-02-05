//!
//! A runtime interface for Uart drivers.
//!

const std = @import("std");
const async_result = @import("async_result.zig");
const interface = @import("interface.zig");

const Uart = @This();

instance: *anyopaque,
vtable: *const VTable,

/// Changes the configuration of the uart.
pub fn configure(uart: Uart, config: Config) ConfigError!void {
    return uart.vtable.configureFn(uart.instance, config);
}

/// Starts an outgoing transfer over `data.len` bytes.
/// The return value is a handle to that transfer and must be passed to `endSend()` when
/// `<result>.isCompleted()` returns `true`.
///
/// The `data` buffer must be valid until a call to `endSend()` as it will be referenced internally.
/// This allows the driver to directly read data from the send buffer instead of copying it into
/// internal fifos or similar.
///
/// There can always be just one active transfer. Another call to `beginReceive()` or `beginSend()`
/// when a transfer is already in progress will return `error.InProgress`!
pub fn beginSend(uart: Uart, data: []const u8, timeout: ?Timeout) BeginSendError!*const AsyncSendResult {
    return uart.vtable.beginSendFn(uart.instance, data, timeout);
}

/// Finalizes a send operation. Pass in the `result` that was returned from a `beginSend()` call earlier.
/// The `data` buffer is then unreferenced and can be invalidated.
pub fn endSend(uart: Uart, result: *const AsyncSendResult) SendResult {
    return uart.vtable.endSendFn(uart.instance, result);
}

/// Starts an incoming transfer over `buffer.len` bytes.
/// The return value is a handle to that transfer and must be passed to `endReceive()` when
/// `<result>.isCompleted()` returns `true`.
///
/// There can always be just one active transfer. Another call to `beginReceive()` or `beginSend()`
/// when a transfer is already in progress will return `error.InProgress`!
pub fn beginReceive(uart: Uart, buffer: []u8, timeout: ?Timeout) BeginReceiveError!*const AsyncReceiveResult {
    return uart.vtable.beginReceiveFn(uart.instance, buffer, timeout);
}

/// Finalizes a receive operation. Pass in the `result` that was returned from a `beginReceive()` call earlier.
/// The function then returns both the number of bytes written into the `buffer` that was passed into `beginReceive()`,
/// as well as a potential error that has stopped the transfer. If no error happened, all bytes in `buffer` were written.
pub fn endReceive(uart: Uart, result: *const AsyncReceiveResult) ReceiveResult {
    return uart.vtable.endReceiveFn(uart.instance, result);
}

/// A UART configuration. The config defaults to the *8N1* setting, so "8 data bits, no parity, 1 stop bit" which is the
/// most common serial format.
pub const Config = struct {
    /// Desired baud rate. If `null`, will use the autobaud mechanism to detect the
    /// actual baud rate.
    baud_rate: ?u32,

    /// Determines the resting time after the data bits are transferred.
    stop_bits: StopBits = .one,

    /// Determines if an additional parity bit is transferred, and if os
    /// how the parity bit is computed.
    parity: ?Parity = null,

    /// Determines how many bits are transferred per word.
    data_bits: DataBits = .eight,

    /// The control flow that is used for this communication.
    control_flow: ControlFlow = .none,

    /// The maximum acceptable error for the baud rate in permille. `configure()` will return an `error.BaudRatePrecision` when
    /// the system clock is too imprecise to set the desired baud rate and the clock error will exceed this value.
    ///
    /// The default of two percent is chosen in a way that a regular 8N1 transfer is in a safe margin.
    /// For an explanation of the default value, check out https://community.silabs.com/s/article/uart-rs232-required-clock-accuracy.
    max_baud_error: u16 = 20, // 2%
};

pub const ControlFlow = union(enum) {
    /// No control flow is performed.
    none,

    /// Using XON, XOFF symbols
    software,

    /// Using hardware control flow with RTS/CTS
    hardware,

    /// Using custom symbols for start/receive sending
    custom_software: CustomSoftwareControlFlow,
};

pub const CustomSoftwareControlFlow = struct {
    /// This byte is sent when the opposite site should stop sending data.
    pause_request: u8,

    /// This byte is sent when the opposite site can send data again.
    resume_request: u8,
};

/// A timeout in microseconds composed of a constant and variable part.
/// The total timeout is computed by `transferred_len * variable + constant`.
/// This way, a generic timeout can be used for both short and long transfers.
pub const Timeout = struct {
    constant: u32,
    variable: u32,
};

pub const ConfigError = error{
    /// Configuration cannot be changed as an active transfer is still in progress.
    /// Retry when no send or receive transfer is active.
    TransferInProgress,

    /// The chosen baud rate is supported, but the system clock is too imprecise to
    /// safely operate the uart, as the clock error rate exceeds `Config.max_baud_error`.
    BaudRatePrecision,

    AutoBaudNotSupported,
    BaudRateNotSupported,
    StopBitsNotSupported,
    WordSizeNotSupported,
    ParityNotSupported,
    ControlFlowNotSupported,
};

pub const BeginSendError = error{InProgress};
pub const BeginReceiveError = error{InProgress};

pub const SendError = error{
    /// The transfer could not be completed in a predefined time span,
    /// due to control flow preventing sending data.
    Timeout,
};

pub const ReceiveError = error{
    /// The input buffer received a byte while the receive fifo is already full.
    /// Devices with no fifo fill overrun as soon as a second byte arrives.
    BufferOverrun,

    /// A byte with an invalid parity bit was received.
    ParityError,

    /// The stop bit of our byte was not valid.
    FramingError,

    /// The break interrupt error will happen when RXD is logic zero for
    /// the duration of a full transfer (start bit, data bits, parity, stop bits).
    BreakInterrupt,

    /// The transfer could not be completed in a predefined time span.
    Timeout,
};

pub const SendResult = struct {
    /// If not `.none`, an error happened during the transfer and cancelled
    /// receiption.
    @"error": ?SendError,

    /// The number of bytes sent before `error` happened.
    bytes_transferred: usize,
};

pub const ReceiveResult = struct {
    /// If not `.none`, an error happened during the transfer and cancelled
    /// receiption.
    @"error": ?ReceiveError,

    /// The number of bytes received before `error` happened.
    bytes_transferred: usize,
};

pub const AsyncSendResult = async_result.AsyncResult(SendResult);
pub const AsyncReceiveResult = async_result.AsyncResult(ReceiveResult);

/// Number of bits in a data word of the serial transmission.
/// Nine bit transfers are not supported in the standard interface
/// as they require a type larger than `u8` for the `write()` function.
/// This would complicate the interface unnecessarily. Use a concrete
/// instance instead of the runtime interface if you need a 9 bit transfer.
pub const DataBits = enum(u4) {
    five = 5,
    six = 6,
    seven = 7,
    eight = 8,
};

/// Delay time after the transmission of data bits.
pub const StopBits = enum {
    /// Wait the time of a single bit before transferring the next word.
    one,

    /// Wait the time of 1.5 bits before transferring the next word.
    one_point_five,

    /// Wait the time of two bits before transferring the next word.
    two,
};

/// Defines the variant of an optional parity/checksum bit.
pub const Parity = enum {
    /// No parity bit is sent.
    none,

    /// The parity bit is always `1`.
    mark,

    /// The parity bit is always `0`.
    space,

    /// The parity bit is computed in a way that the number of `1` bits in the transfer is even.
    even,

    /// The parity bit is computed in a way that the number of `1` bits in the transfer is odd.
    odd,
};

pub const Interface = interface.Interface(struct {
    configure: fn (interface.Self, Config) ConfigError!void,

    beginSend: fn (interface.Self, data: []const u8, ?Timeout) BeginSendError!*const AsyncSendResult,
    endSend: fn (interface.Self, result: *const AsyncSendResult) SendResult,

    beginReceive: fn (interface.Self, []u8, ?Timeout) BeginReceiveError!*const AsyncReceiveResult,
    endReceive: fn (interface.Self, *const AsyncReceiveResult) ReceiveResult,
});

pub const VTable = Interface.VTable;

comptime {
    Interface.verify(@This());
}

const TestImpl = struct {
    const Self = @This();

    send_result: AsyncSendResult = .{},
    receive_result: AsyncReceiveResult = .{},

    pub fn configure(impl: TestImpl, config: Config) ConfigError!void {
        _ = impl;
        _ = config;
    }

    pub fn beginSend(impl: TestImpl, data: []const u8, timeout: ?Timeout) BeginSendError!*const AsyncSendResult {
        _ = data;
        _ = timeout;
        return &impl.send_result;
    }

    pub fn endSend(impl: TestImpl, result: *const AsyncSendResult) SendResult {
        std.debug.assert(&impl.send_result == result);
        return SendResult{
            .@"error" = error.Timeout,
            .bytes_transferred = 0,
        };
    }

    pub fn beginReceive(impl: TestImpl, buffer: []u8, timeout: ?Timeout) BeginReceiveError!*const AsyncReceiveResult {
        _ = buffer;
        _ = timeout;
        return &impl.receive_result;
    }

    pub fn endReceive(impl: TestImpl, result: *const AsyncReceiveResult) ReceiveResult {
        std.debug.assert(&impl.receive_result == result);
        return ReceiveResult{
            .@"error" = error.Timeout,
            .bytes_transferred = 0,
        };
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
