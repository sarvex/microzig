const std = @import("std");
const micro = @import("microzig");

const uart_instance = &micro.chip.uart0;

pub fn main() !void {
    const uart_ptr = micro.interface.Uart.new(uart_instance);

    try uart_ptr.configure(.{
        .baud_rate = 115_200,
    });

    var transfer = micro.interface.Uart.SendTransfer{
        .data = "Hello, World!\r\n",
        .timeout = null,
    };
    try uart_ptr.send(&transfer);

    var buffer: [1]u8 = undefined;
    var inbound = micro.interface.Uart.ReceiveTransfer{
        .data = &buffer,
        .timeout = null,
    };
    try uart_ptr.receive(&inbound);

    while (true) {
        if (inbound.done) {
            const received_data = inbound.data[0..inbound.bytes_transferred];

            // TODO: Process received_data
            if (received_data.len > 0) {
                std.log.info("UART received the following data: '{}'", .{std.fmt.fmtSliceEscapeUpper(received_data)});
            }

            // we received data from the UART.
            if (inbound.@"error") |err| {
                std.log.err("UART failed during reception of data: {s}", .{@errorName(err)});
            }

            // Just reschedule our task
            try uart_ptr.receive(&inbound);
        }

        uart_instance.tick();
    }
}

pub const clock_frequencies = micro.clock.Clocks{
    .cpu = 16_000_000,
};
