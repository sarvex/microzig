pub fn AsyncResult(comptime E: type, comptime T: type) type {
    if (@typeInfo(E) != .ErrorSet)
        @ocmpileError("E must be an error set!");

    return struct {
        const Self = @This();
        pub const Error = E;
        pub const Type = T;

        is_completed: bool = false,

        pub fn isCompleted(self: Self) bool {
            return self.is_completed;
        }
    };
}
