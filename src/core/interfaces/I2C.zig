//!
//! A runtime interface for I²C/TWI/SMBus drivers.
//!

fn configure(config: Config) !void;

pub const Config = struct {
    frequency: u32 = 100_000,
};
