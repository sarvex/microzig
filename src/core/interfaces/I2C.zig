//!
//! A runtime interface for I²C/TWI/SMBus drivers.
//!

fn configure(config: Config) !void;

fn beginRead(device: u7) *const ReadTransfer;
fn read(transfer: *ReadTransfer, data: []u8) usize;
fn endRead(transfer: *const ReadTransfer, restart: bool) void;

fn beginWrite(device: u7) *const WriteTransfer;
fn write(transfer: *WriteTransfer, data: []const u8) usize;
fn endWrite(transfer: *const WriteTransfer, restart: bool) void;

pub const Config = struct {
    frequency: u32 = 100_000,
};
