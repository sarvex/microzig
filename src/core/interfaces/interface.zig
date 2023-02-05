const std = @import("std");

const Type = std.builtin.Type;

pub const Self = struct {};

pub fn Interface(comptime Spec: type) type {
    const spec_fields: []const Type.StructField = @typeInfo(Spec).Struct.fields;

    for (spec_fields) |fld| {
        if (@typeInfo(fld.type) != .Fn)
            @compileError("Each field in the interface specification structure must be of a function type!");
    }

    return struct {
        const Intf = @This();

        fn unmapSelfTypeFromFn(comptime F: type) type {
            const src_fun: Type.Fn = @typeInfo(F).Fn;

            var params_clone = src_fun.params[0..src_fun.params.len].*;
            for (params_clone) |*fld| {
                if (fld.type == Self) {
                    fld.type = *anyopaque;
                }
            }

            var dst_fun = src_fun;
            dst_fun.params = &params_clone;
            return @Type(.{ .Fn = dst_fun });
        }

        pub const VTable = blk: {
            var fields: []const Type.StructField = &.{};

            for (spec_fields) |src_field| {
                const func_type = *const unmapSelfTypeFromFn(src_field.type);

                const field = Type.StructField{
                    .name = src_field.name,
                    .type = func_type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(func_type),
                };

                fields = fields ++ [1]Type.StructField{field};
            }

            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .fields = fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        // comptime {
        //     @compileLog("VTable:");
        //     for (std.meta.fields(VTable)) |fld| {
        //         @compileLog(fld.name, fld.type);
        //     }
        // }

        /// Implements a VTable based on the given type. As long as the signatures
        /// of the functions are matching, a vtable can be constructed.
        pub fn constructVTable(comptime T: type) *const VTable {
            const Implementation = struct {
                fn cast(erased_self: *anyopaque) *T {
                    return @ptrCast(*T, if (@alignOf(T) == 0)
                        erased_self
                    else
                        @alignCast(@alignOf(T), erased_self));
                }

                const vtable: VTable = blk: {
                    var table: VTable = undefined;

                    for (std.meta.fields(VTable)) |fld, spec_index| {
                        const spec_source = @typeInfo(spec_fields[spec_index].type).Fn;

                        const Func = @typeInfo(fld.type).Pointer.child;

                        const Invoker = struct {
                            fn invoke(s_args: std.meta.ArgsTuple(Func)) @typeInfo(Func).Fn.return_type.? {
                                const target_func = @field(T, fld.name);

                                const TargetFunc = @TypeOf(target_func);

                                const TargetArgs = std.meta.ArgsTuple(TargetFunc);

                                var t_args: TargetArgs = undefined;

                                inline for (std.meta.fields(TargetArgs)) |param, i| {
                                    @field(t_args, param.name) = if (spec_source.params[i].type == Self)
                                        if (param.type == T)
                                            cast(@field(s_args, param.name)).*
                                        else
                                            cast(@field(s_args, param.name))
                                    else
                                        @field(s_args, param.name);
                                }

                                return @call(.auto, target_func, t_args);
                            }
                        };

                        @field(table, fld.name) = autoInvokeN(Invoker.invoke).invoke;
                    }

                    break :blk table;
                };

                // fn configureFn(erased_self: *anyopaque, cfg: Config) ConfigError!void {
                //     return cast(erased_self).configure(cfg);
                // }
            };

            return &Implementation.vtable;
        }

        /// Performs type verification of `T` if it matches the `Uart` interface.
        /// If `T` doesn't conform to the interface, a compile error is raised.
        ///
        /// Call this function at `comptime` for each driver implementation of an `Uart`
        /// you create, so that new these drivers conform to the common interface.
        ///
        /// Use this convenience snippet in your driver type to do that:
        /// ```zig
        /// comptime {
        ///     Interface.verify(@This());
        /// }
        /// ```
        pub fn verify(comptime T: type) void {
            switch (@typeInfo(T)) {
                .Struct, .Union, .Enum => {},
                else => @compileError("The interface can only be implemented by a concrete struct, union or enum!"),
            }

            inline for (spec_fields) |fld| {
                const expected_name = fld.name;
                const expected_func = fld.type;
                const expected_info: Type.Fn = @typeInfo(expected_func).Fn;

                if (!@hasDecl(T, expected_name)) {
                    @compileError(std.fmt.comptimePrint("missing function {s}", .{expected_name}));
                }

                const info: std.builtin.Type.Fn = @typeInfo(@TypeOf(@field(T, expected_name))).Fn;
                const return_type: type = expected_info.return_type.?;

                if (info.params.len != expected_info.params.len) {
                    @compileError(std.fmt.comptimePrint("parameter count mismatch for {s}: expected {} parameters, but provided function has {} parameters", .{
                        expected_name,
                        expected_info.params.len,
                        info.params.len,
                    }));
                }
                if (info.return_type != return_type) {
                    @compileError(std.fmt.comptimePrint("return type mismatch for {s}: expected return type {s}, but provided function has return type {s}", .{
                        expected_name,
                        @typeName(return_type),
                        @typeName(info.return_type orelse unreachable),
                    }));
                }
                inline for (expected_info.params) |item, i| {
                    const param_type = item.type.?;
                    if (param_type == Self)
                        continue;
                    if (info.params[i].type != param_type) {
                        @compileError(std.fmt.comptimePrint("signature mismatch for {s}: parameter {} is expected to be of type {s}, but is type {s}", .{
                            expected_name,
                            i,
                            @typeName(param_type),
                            @typeName(info.params[i].type orelse unreachable),
                        }));
                    }
                }
            }
        }
    };
}

fn ParamType(comptime Tuple: type, comptime i: comptime_int) type {
    return @typeInfo(Tuple).Struct.fields[i].type;
}

fn autoInvokeN(comptime function: anytype) type {
    const Func = @TypeOf(function);

    const info: Type.Fn = @typeInfo(Func).Fn;
    if (info.params.len != 1)
        @compileError("autoInvoke function must have exactly one parameter!");

    const ReturnType = info.return_type.?;

    const Tuple = info.params[0].type.?;

    const param_count = @typeInfo(Tuple).Struct.fields.len;

    // #!/usr/bin/lua
    // for param_count = 0, 64 do -- should be enough for everyone
    //   -- 2 => struct {
    //   --   pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1)) ReturnType {
    //   --       return function(.{ a0, a1 });
    //   --   }
    //   -- },

    //   io.write(tostring(param_count), " => struct { pub fn invoke(")
    //   for j = 0, param_count - 1 do
    //     if j > 0 then
    //       io.write(", ")
    //     end
    //     io.write(("a%d: ParamType(Tuple, %d)"):format(j, j))
    //   end
    //   io.write(") ReturnType { return @call(.always_inline, function, .{ .{")
    //   for j = 0, param_count - 1 do
    //     if j > 0 then
    //       io.write(", ")
    //     end
    //     io.write(("a%d"):format(j))
    //   end
    //   io.write("} });} },\n")

    // end

    return switch (param_count) {
        0 => struct {
            pub fn invoke() ReturnType {
                return @call(.always_inline, function, .{.{}});
            }
        },
        1 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0)) ReturnType {
                return @call(.always_inline, function, .{.{a0}});
            }
        },
        2 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1 }});
            }
        },
        3 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2 }});
            }
        },
        4 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3 }});
            }
        },
        5 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4 }});
            }
        },
        6 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5 }});
            }
        },
        7 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6 }});
            }
        },
        8 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7 }});
            }
        },
        9 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8 }});
            }
        },
        10 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 }});
            }
        },
        11 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 }});
            }
        },
        12 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 }});
            }
        },
        13 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 }});
            }
        },
        14 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13 }});
            }
        },
        15 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14 }});
            }
        },
        16 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 }});
            }
        },
        17 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16 }});
            }
        },
        18 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17 }});
            }
        },
        19 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18 }});
            }
        },
        20 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19 }});
            }
        },
        21 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20 }});
            }
        },
        22 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21 }});
            }
        },
        23 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22 }});
            }
        },
        24 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23 }});
            }
        },
        25 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24 }});
            }
        },
        26 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25 }});
            }
        },
        27 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26 }});
            }
        },
        28 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27 }});
            }
        },
        29 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28 }});
            }
        },
        30 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29 }});
            }
        },
        31 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30 }});
            }
        },
        32 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31 }});
            }
        },
        33 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32 }});
            }
        },
        34 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33 }});
            }
        },
        35 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34 }});
            }
        },
        36 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35 }});
            }
        },
        37 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36 }});
            }
        },
        38 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37 }});
            }
        },
        39 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38 }});
            }
        },
        40 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39 }});
            }
        },
        41 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40 }});
            }
        },
        42 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41 }});
            }
        },
        43 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42 }});
            }
        },
        44 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43 }});
            }
        },
        45 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44 }});
            }
        },
        46 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45 }});
            }
        },
        47 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46 }});
            }
        },
        48 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47 }});
            }
        },
        49 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48 }});
            }
        },
        50 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49 }});
            }
        },
        51 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50 }});
            }
        },
        52 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51 }});
            }
        },
        53 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52 }});
            }
        },
        54 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53 }});
            }
        },
        55 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54 }});
            }
        },
        56 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55 }});
            }
        },
        57 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56 }});
            }
        },
        58 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56), a57: ParamType(Tuple, 57)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56, a57 }});
            }
        },
        59 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56), a57: ParamType(Tuple, 57), a58: ParamType(Tuple, 58)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56, a57, a58 }});
            }
        },
        60 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56), a57: ParamType(Tuple, 57), a58: ParamType(Tuple, 58), a59: ParamType(Tuple, 59)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56, a57, a58, a59 }});
            }
        },
        61 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56), a57: ParamType(Tuple, 57), a58: ParamType(Tuple, 58), a59: ParamType(Tuple, 59), a60: ParamType(Tuple, 60)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56, a57, a58, a59, a60 }});
            }
        },
        62 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56), a57: ParamType(Tuple, 57), a58: ParamType(Tuple, 58), a59: ParamType(Tuple, 59), a60: ParamType(Tuple, 60), a61: ParamType(Tuple, 61)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56, a57, a58, a59, a60, a61 }});
            }
        },
        63 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56), a57: ParamType(Tuple, 57), a58: ParamType(Tuple, 58), a59: ParamType(Tuple, 59), a60: ParamType(Tuple, 60), a61: ParamType(Tuple, 61), a62: ParamType(Tuple, 62)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56, a57, a58, a59, a60, a61, a62 }});
            }
        },
        64 => struct {
            pub fn invoke(a0: ParamType(Tuple, 0), a1: ParamType(Tuple, 1), a2: ParamType(Tuple, 2), a3: ParamType(Tuple, 3), a4: ParamType(Tuple, 4), a5: ParamType(Tuple, 5), a6: ParamType(Tuple, 6), a7: ParamType(Tuple, 7), a8: ParamType(Tuple, 8), a9: ParamType(Tuple, 9), a10: ParamType(Tuple, 10), a11: ParamType(Tuple, 11), a12: ParamType(Tuple, 12), a13: ParamType(Tuple, 13), a14: ParamType(Tuple, 14), a15: ParamType(Tuple, 15), a16: ParamType(Tuple, 16), a17: ParamType(Tuple, 17), a18: ParamType(Tuple, 18), a19: ParamType(Tuple, 19), a20: ParamType(Tuple, 20), a21: ParamType(Tuple, 21), a22: ParamType(Tuple, 22), a23: ParamType(Tuple, 23), a24: ParamType(Tuple, 24), a25: ParamType(Tuple, 25), a26: ParamType(Tuple, 26), a27: ParamType(Tuple, 27), a28: ParamType(Tuple, 28), a29: ParamType(Tuple, 29), a30: ParamType(Tuple, 30), a31: ParamType(Tuple, 31), a32: ParamType(Tuple, 32), a33: ParamType(Tuple, 33), a34: ParamType(Tuple, 34), a35: ParamType(Tuple, 35), a36: ParamType(Tuple, 36), a37: ParamType(Tuple, 37), a38: ParamType(Tuple, 38), a39: ParamType(Tuple, 39), a40: ParamType(Tuple, 40), a41: ParamType(Tuple, 41), a42: ParamType(Tuple, 42), a43: ParamType(Tuple, 43), a44: ParamType(Tuple, 44), a45: ParamType(Tuple, 45), a46: ParamType(Tuple, 46), a47: ParamType(Tuple, 47), a48: ParamType(Tuple, 48), a49: ParamType(Tuple, 49), a50: ParamType(Tuple, 50), a51: ParamType(Tuple, 51), a52: ParamType(Tuple, 52), a53: ParamType(Tuple, 53), a54: ParamType(Tuple, 54), a55: ParamType(Tuple, 55), a56: ParamType(Tuple, 56), a57: ParamType(Tuple, 57), a58: ParamType(Tuple, 58), a59: ParamType(Tuple, 59), a60: ParamType(Tuple, 60), a61: ParamType(Tuple, 61), a62: ParamType(Tuple, 62), a63: ParamType(Tuple, 63)) ReturnType {
                return @call(.always_inline, function, .{.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, a32, a33, a34, a35, a36, a37, a38, a39, a40, a41, a42, a43, a44, a45, a46, a47, a48, a49, a50, a51, a52, a53, a54, a55, a56, a57, a58, a59, a60, a61, a62, a63 }});
            }
        },
        else => @compileError(std.fmt.comptimePrint("auto-unwrapping of a {}-ary function isn't supported yet!", .{param_count})),
    };
}
