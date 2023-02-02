//!
//! A runtime interface for Uart drivers.
//!

const Uart = @This();

const async_result = @import("async_result.zig");

instance: *anyopaque,
vtable: *const VTable,

/// Changes the configuration of the uart.
pub fn configure(uart: Uart, config: Config) ConfigError!void {
    return uart.configureFn(uart.instance, config);
}

/// Sends `data` and returns the number of bytes actually sent.
/// The return value might be smaller than `data.len` as most uarts
/// have limited send buffers and might be in a non-blocking mode.
/// A return value of zero is allowed and signals that there is currently
/// no space in a send buffer.
pub fn send(uart: Uart, data: []const u8) SendError!usize {
    return uart.vtable.sendFn(uart.instance, data);
}

/// Starts an incoming transfer over `buffer.len` bytes.
/// The return value is a handle to that transfer and must be passed to `endReceive()` when
/// `<result>.isCompleted()` returns `true`.
///
/// There can always be just one active transfer. Another call to `beginReceive()` when a
/// transfer is already in progress will return `error.InProgress`!
pub fn beginReceive(uart: Uart, buffer: []u8) BeginReceiveError!*const AsyncResult {
    return uart.vtable.beginReceiveFn(uart.instance, buffer);
}

/// Finalizes a receive operation. Pass in the `result` that was returned from a `beginReceive()` call earlier.
/// The function then returns the number of bytes written into the `buffer` that was passed into `beginReceive()`.
pub fn endReceive(uart: Uart, result: *const AsyncResult) ReceiveError!usize {
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
};

pub const VTable = struct {
    configureFn: *const fn (*anyopaque, Config) ConfigError!void,
    sendFn: *const fn (*anyopaque, []const u8) SendError!usize,

    beginReceiveFn: *const fn (*anyopaque, []u8) BeginReceiveError!*const AsyncResult,
    endReceiveFn: *const fn (*anyopaque, *const AsyncResult) ReceiveError!usize,
};

pub const ConfigError = error{
    UnsupportedBaudRate,
    UnsupportedStopBits,
    UnsupportedWordSize,
    UnsupportedParity,
};

pub const SendError = error{Timeout};

pub const BeginReceiveError = error{
    InProgress,
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

pub const AsyncResult = async_result.AsyncResult(ReceiveError, usize);

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

pub const StopBits = enum {
    /// Wait the time of a single bit before transferring the next word.
    one,

    /// Wait the time of 1.5 bits before transferring the next word.
    one_point_five,

    /// Wait the time of two bits before transferring the next word.
    two,
};

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
