/// A timeout in microseconds composed of a constant and variable part.
/// The total timeout is computed by `transferred_len * variable + constant`.
/// This way, a generic timeout can be used for both short and long transfers.
const Timeout = @This();

constant: u32,
variable: u32,
