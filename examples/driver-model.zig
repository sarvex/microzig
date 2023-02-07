//!
//! Usage example for microzig.core driver model.
//!
//! The design created here is using a software bitbang
//! SPI where the bus is attached to an I²C port expander
//! that is driven by a software I²C created by another
//! port expander of the same type.
//!
//! Attached to the SPI is a small SSD1306 OLED display with
//! 128x64 pixels:
//!
//! ```
//! .-----.           .---------.           .---------.           .---------.
//! |     |           |         |           |         |           |         |
//! | MCU | <= I²C => | TCA9534 | <= I²C => | TCA9534 | <= SPI => | SSD1306 |
//! |     |           |         |           |         |           |         |
//! '-----'           '---------'           '---------'           '---------'
//! ```
//!
//! This example is obviously pretty stupid to design like this, but shows
//! the power of the new driver model
//!
const microzig = @import("microzig");

const SoftSPI = microzig.drivers.SoftSPI(*TCA9534); // specialize SoftI2C on the TCA driver, as we only use it with this and don't share impls.
const SoftI2C = microzig.drivers.SoftI2C_For(*TCA9534); // specialize SoftI2C on the TCA driver, as we only use it with this and don't share impls.
const HardI2C = microzig.hal.I2C;
const TCA9534 = @import("microzig.driver.tca9534").TCA9534; // use the generic version here as well, as we want to use the same display later on at another port as well
const Display128x64 = @import("microzig.driver.ssd1306").Display128x64_For(*SoftSPI); // specialize display driver for SoftSPI, as we don't use it over any other spi anyways

var root_i2c: HardI2C = undefined;
var soft_i2c_root: TCA9534 = undefined;
var soft_i2c: SoftI2C = undefined;
var soft_spi_root: TCA9534 = undefined;
var soft_spi: SoftSPI = undefined;
var display: Display128x64 = undefined;

pub fn main() !void {
    // initialize the I²C hardware peripherial
    try root_i2c.init(try microzig.hal.pin("PC4"), try microzig.hal.pin("PC5")); // PC4=>SDA, PC5=>SCL

    // Initialize first port expander with the hardware I²C,
    // this will also call configure() on the `root_i2c` object.
    try soft_i2c_root.init(microzig.interface.I2C.new(&root_i2c));

    // initialize the software I²C driver based on the port expanders
    // GPIO interface. Using the pin abstraction, we can use not only pins from
    // the system, but also created from the port expander itself.
    // We're passing in the TCA9534 as a pointer instead of using the vtable interface
    // as we've specified above that we use a direct implementation instead of
    // using the generic virtual dispatch one.
    try soft_i2c.init(&soft_i2c_root, TCA9534.pin("P0"), TCA9534.pin("P1"));

    // Same game as above with `soft_i2c_root`, but this time, using the software bitbanged I²C
    // instead of the hardware one. The virtual dispatch here prevents us from instantiating the
    // driver code twice, thus saving generic bloat.
    try soft_spi_root.init(microzig.interface.I2C.new(&soft_i2c));

    // same game as with the `soft_i2c` module, but for the software SPI.
    try soft_spi.init(&soft_spi_root, TCA9534.pin("P3"), TCA9534.pin("P4"), TCA9534.pin("P5")); // P3=>SCK, P4=>MOSI, P5=>MISO

    // Initialize the display on top of the software SPI.
    try display.init(microzig.interface.SPI.new(&soft_spi), try soft_spi_root.pin("P6")); // P6=>CS

    // Set up some nice test image:
    try display.clear(.off);
    try display.setPixel(20, 20, .on);
    try display.setPixel(21, 20, .on);
    try display.setPixel(19, 20, .on);
    try display.setPixel(20, 21, .on);
    try display.setPixel(20, 19, .on);

    while (true) {
        // Tick could maybe be implemented via a global "tick" system
        display.tick();
        soft_spi.tick();
        soft_spi_root.tick();
        soft_i2c.tick();
        soft_i2c_root.tick();
        root_i2c.tick();

        microzig.waitForInterrupt();
    }
}
