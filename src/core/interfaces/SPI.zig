//!
//! A runtime interface for SPI drivers.
//!

const std = @import("std");
const async_result = @import("async_result.zig");

const SPI = @This();

pub fn configure(spi: SPI, config: Config) !void {
    //
}

pub fn beginRead(spi: SPI, data: []u8, out_byte: u8) BeginTransferError!*const ReadAsyncResult {
    //
}
pub fn endWrite(spi: SPI, transfer: *const ReadAsyncResult) void {
    //
}

pub fn beginWrite(spi: SPI, data: []const u8) BeginTransferError!*const WriteAsyncResult {
    //
}
pub fn endWrite(spi: SPI, transfer: *const WriteAsyncResult) void {
    //
}

pub fn beginBiDiTransfer(spi: SPI, out_data: []const u8, in_data: []const u8) BeginTransferError!*const BiDiAsyncResult {
    //
}
pub fn endBiDiTransfer(spi: SPI, transfer: *const BiDiAsyncResult) void {
    //
}

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

pub const BeginTransferError = error{
    InProgress,
};

pub const ReadAsyncResult = async_result.AsyncResult(opaque {});
pub const WriteAsyncResult = async_result.AsyncResult(opaque {});
pub const BiDiAsyncResult = async_result.AsyncResult(opaque {});
