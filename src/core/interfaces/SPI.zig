//!
//! A runtime interface for SPI drivers.
//!

fn configure(config: Config) !void;

fn beginRead(data: []u8) *const ReadTransfer;
fn endWrite(tansfer: *const ReadTransfer) !usize;

fn beginWrite(data: []const u8) *const WriteTransfer;
fn endWrite(tansfer: *const WriteTransfer) !usize;

pub const Config = struct {
    frequency: u32 = 100_000,

    clock_idle_polarity: enum(u1) { low = 0, high = 1 }, // CPOL
    clock_data_valid_edge: enum(u1) { leading = 0, trailing = 1 }, // CPHA
};
