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

    while (true) {
        uart_instance.tick();
    }
}

pub const clock_frequencies = micro.clock.Clocks{
    .cpu = 16_000_000,
};
