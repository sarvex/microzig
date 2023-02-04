pub fn AsyncResult(comptime Tag: type) type {
    return struct {
        const Self = @This();
        pub const TagType = Tag;

        is_completed: bool = false,

        pub fn isCompleted(self: Self) bool {
            return self.is_completed;
        }
    };
}
