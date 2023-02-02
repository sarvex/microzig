

so my current chain of thought is:

- microzig.core defines abstract interface types for I2C, SPI, UART and so on
- microzig.core provides a runtime dispatch implementation for said interface.
- microzig.chip.* implements UART drivers providing the core.UART interface
- microzig.driver.Terminal is a hilevel driver impl for a serial user terminal
- microzig.driver.Terminal = microzig.driver.TerminalBasedOn(microzig.core.UART) (so the regular driver uses runtime dispatch, but theres the option to instantiate on concrete impls)

what we gain:
- high perf when wanted
- small code when wanted
- sharing drivers between devices
- nested devices are possible (spi attached i2c master)
- this design allows unit testing of drivers by using the runtime dispatch interface
- we could also provide microzig.RegisterView for I2C and SPI devices that allows writing/reading via generic properties, for drivers like ssd1306

requirements:
- microzig gotta define the interface including potential errors (fixed error sets)


