const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Step = std.build.Step;
const GeneratedFile = std.build.GeneratedFile;

pub const LinkerScriptStep = @import("modules/LinkerScriptStep.zig");
pub const boards = @import("modules/boards.zig");
pub const chips = @import("modules/chips.zig");
pub const cpus = @import("modules/cpus.zig");
pub const Board = @import("modules/Board.zig");
pub const Chip = @import("modules/Chip.zig");
pub const Cpu = @import("modules/Cpu.zig");

pub const Backing = union(enum) {
    board: Board,
    chip: Chip,

    pub fn getTarget(self: @This()) std.zig.CrossTarget {
        return switch (self) {
            .board => |brd| brd.chip.cpu.target,
            .chip => |chip| chip.cpu.target,
        };
    }
};

const Pkg = std.build.Pkg;
const root_path = root() ++ "/";
fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}

pub const BuildOptions = struct {};

pub const EmbeddedExecutable = struct {
    inner: *LibExeObjStep,
    app_packages: std.ArrayList(Pkg),
    microzig_pkg: *MicroZigPkg,

    pub fn addPackage(exe: *EmbeddedExecutable, pkg: Pkg) void {
        exe.app_packages.append(pkg) catch @panic("failed to append");

        for (exe.inner.packages.items) |*entry| {
            if (std.mem.eql(u8, "app", entry.name)) {
                entry.dependencies = exe.app_packages.items;
                break;
            }
        } else @panic("app package not found");
    }

    pub fn addPackagePath(exe: *EmbeddedExecutable, name: []const u8, pkg_index_path: []const u8) void {
        exe.addPackage(Pkg{
            .name = exe.inner.builder.allocator.dupe(u8, name) catch unreachable,
            .source = .{ .path = exe.inner.builder.allocator.dupe(u8, pkg_index_path) catch unreachable },
        });
    }

    /// a HAL is a package who depends on microzig
    pub fn addHalPackage(exe: *EmbeddedExecutable, name: []const u8, source: std.build.FileSource) void {
        exe.addPackage(.{
            .name = name,
            .source = source,
            .dependencies = &.{exe.microzig_pkg.toPackage()},
        });
    }

    pub fn setBuildMode(exe: *EmbeddedExecutable, mode: std.builtin.Mode) void {
        exe.inner.setBuildMode(mode);
    }

    pub fn install(exe: *EmbeddedExecutable) void {
        exe.inner.install();
    }

    pub fn installRaw(
        exe: *EmbeddedExecutable,
        dest_filename: []const u8,
        options: std.build.InstallRawStep.CreateOptions,
    ) *std.build.InstallRawStep {
        return exe.inner.installRaw(dest_filename, options);
    }

    pub fn addIncludePath(exe: *EmbeddedExecutable, path: []const u8) void {
        exe.inner.addIncludePath(path);
    }

    pub fn addSystemIncludePath(exe: *EmbeddedExecutable, path: []const u8) void {
        return exe.inner.addSystemIncludePath(path);
    }

    pub fn addCSourceFile(exe: *EmbeddedExecutable, file: []const u8, flags: []const []const u8) void {
        exe.inner.addCSourceFile(file, flags);
    }

    pub fn addOptions(exe: *EmbeddedExecutable, package_name: []const u8, options: *std.build.OptionsStep) void {
        exe.inner.addOptions(package_name, options);
        exe.addPackage(.{ .name = package_name, .source = options.getSource() });
    }

    pub fn addObjectFile(exe: *EmbeddedExecutable, source_file: []const u8) void {
        exe.inner.addObjectFile(source_file);
    }
};

pub fn addEmbeddedExecutable(
    builder: *std.build.Builder,
    name: []const u8,
    source: []const u8,
    backing: Backing,
    options: BuildOptions,
) EmbeddedExecutable {
    _ = options;
    const has_board = (backing == .board);
    const chip = switch (backing) {
        .chip => |c| c,
        .board => |b| b.chip,
    };

    const config_file_name = blk: {
        const hash = hash_blk: {
            var hasher = std.hash.SipHash128(1, 2).init("abcdefhijklmnopq");

            hasher.update(chip.name);
            hasher.update(chip.path);
            hasher.update(chip.cpu.name);
            hasher.update(chip.cpu.path);

            if (backing == .board) {
                hasher.update(backing.board.name);
                hasher.update(backing.board.path);
            }

            var mac: [16]u8 = undefined;
            hasher.final(&mac);
            break :hash_blk mac;
        };

        const file_prefix = "zig-cache/microzig/config-";
        const file_suffix = ".zig";

        var ld_file_name: [file_prefix.len + 2 * hash.len + file_suffix.len]u8 = undefined;
        const filename = std.fmt.bufPrint(&ld_file_name, "{s}{}{s}", .{
            file_prefix,
            std.fmt.fmtSliceHexLower(&hash),
            file_suffix,
        }) catch unreachable;

        break :blk builder.dupe(filename);
    };

    {
        // TODO: let the user override which ram section to use the stack on,
        // for now just using the first ram section in the memory region list
        const first_ram = blk: {
            for (chip.memory_regions) |region| {
                if (region.kind == .ram)
                    break :blk region;
            } else @panic("no ram memory region found for setting the end-of-stack address");
        };

        std.fs.cwd().makeDir(std.fs.path.dirname(config_file_name).?) catch {};
        var config_file = std.fs.cwd().createFile(config_file_name, .{}) catch unreachable;
        defer config_file.close();

        var writer = config_file.writer();
        writer.print("pub const has_board = {};\n", .{has_board}) catch unreachable;
        if (has_board)
            writer.print("pub const board_name = .@\"{}\";\n", .{std.fmt.fmtSliceEscapeUpper(backing.board.name)}) catch unreachable;

        writer.print("pub const chip_name = .@\"{}\";\n", .{std.fmt.fmtSliceEscapeUpper(chip.name)}) catch unreachable;
        writer.print("pub const cpu_name = .@\"{}\";\n", .{std.fmt.fmtSliceEscapeUpper(chip.cpu.name)}) catch unreachable;
        writer.print("pub const end_of_stack = 0x{X:0>8};\n\n", .{first_ram.offset + first_ram.length}) catch unreachable;
    }

    const config_pkg = Pkg{
        .name = "config",
        .source = .{ .path = builder.dupePath(config_file_name) },
    };

    const chip_pkg = Pkg{
        .name = "chip",
        .source = .{ .path = chip.path },
        .dependencies = &.{ config_pkg, pkgs.mmio },
    };

    const cpu_pkg = Pkg{
        .name = "cpu",
        .source = .{ .path = chip.cpu.path },
        .dependencies = &.{ chip_pkg, config_pkg, pkgs.mmio },
    };

    var exe = EmbeddedExecutable{
        .inner = builder.addExecutable(name, root_path ++ "core/microzig.zig"),
        .app_packages = std.ArrayList(Pkg).init(builder.allocator),
        .microzig_pkg = MicroZigPkg.add(builder),
    };

    exe.microzig_pkg.addPackage(config_pkg);
    exe.microzig_pkg.addPackage(chip_pkg);
    exe.microzig_pkg.addPackage(cpu_pkg);

    exe.inner.use_stage1 = true;

    // might not be true for all machines (Pi Pico), but
    // for the HAL it's true (it doesn't know the concept of threading)
    exe.inner.single_threaded = true;
    exe.inner.setTarget(chip.cpu.target);

    const linkerscript = LinkerScriptStep.create(builder, chip) catch unreachable;
    exe.inner.setLinkerScriptPath(.{ .generated = &linkerscript.generated_file });

    // TODO:
    // - Generate the linker scripts from the "chip" or "board" package instead of using hardcoded ones.
    //   - This requires building another tool that runs on the host that compiles those files and emits the linker script.
    //    - src/tools/linkerscript-gen.zig is the source file for this
    exe.inner.bundle_compiler_rt = (exe.inner.target.cpu_arch.? != .avr); // don't bundle compiler_rt for AVR as it doesn't compile right now

    // these packages will be re-exported from core/microzig.zig
    exe.inner.addPackage(config_pkg);
    exe.inner.addPackage(chip_pkg);
    exe.inner.addPackage(cpu_pkg);

    switch (backing) {
        .board => |board| {
            exe.microzig_pkg.addPackage(std.build.Pkg{
                .name = "board",
                .source = .{ .path = board.path },
                .dependencies = &.{ chip_pkg, cpu_pkg, config_pkg, pkgs.mmio },
            });
        },
        else => {},
    }

    exe.inner.addPackage(.{
        .name = "app",
        .source = .{ .path = source },
    });
    exe.microzig_pkg.addAsDependency(exe.inner);
    exe.addPackage(exe.microzig_pkg.toPackage());

    return exe;
}

pub const pkgs = struct {
    pub const mmio = std.build.Pkg{
        .name = "mmio",
        .source = .{ .path = root_path ++ "core/mmio.zig" },
    };
};

/// Generic purpose drivers shipped with microzig
pub const drivers = struct {
    pub const quadrature = std.build.Pkg{
        .name = "microzig.quadrature",
        .source = .{ .path = root_path ++ "drivers/quadrature.zig" },
        .dependencies = &.{pkgs.microzig},
    };

    pub const button = std.build.Pkg{
        .name = "microzig.button",
        .source = .{ .path = root_path ++ "drivers/button.zig" },
        .dependencies = &.{pkgs.microzig},
    };
};

pub const MicroZigPkg = struct {
    step: Step,
    generated_file: GeneratedFile,
    allocator: std.mem.Allocator,
    dependencies: std.ArrayList(Pkg),

    pub fn add(b: *Builder) *MicroZigPkg {
        var ret = b.allocator.create(MicroZigPkg) catch @panic("failed to allocate");
        ret.* = .{
            .step = Step.init(.custom, "microzig_pkg", b.allocator, make),
            .generated_file = GeneratedFile{ .step = &ret.step },
            .allocator = b.allocator,
            .dependencies = std.ArrayList(Pkg).init(b.allocator),
        };

        return ret;
    }

    pub fn addPackage(self: *MicroZigPkg, pkg: Pkg) void {
        self.dependencies.append(pkg) catch @panic("failed to append package");
    }

    pub fn toPackage(self: *MicroZigPkg) Pkg {
        return Pkg{
            .name = "microzig",
            .source = .{ .generated = &self.generated_file },
            .dependencies = self.dependencies.items,
        };
    }

    pub fn addAsDependency(self: *MicroZigPkg, other: *LibExeObjStep) void {
        other.addPackage(self.toPackage());
        other.step.dependOn(&self.step);
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(MicroZigPkg, "step", step);
        var hasher = std.hash.SipHash128(1, 2).init("abcdefhijklmnopq");

        // hash contents
        for (self.dependencies.items) |dependency|
            hasher.update(dependency.name);

        var mac: [16]u8 = undefined;
        hasher.final(&mac);

        const filename = try std.fmt.allocPrint(self.allocator, "{}{s}", .{
            std.fmt.fmtSliceHexLower(&mac),
            ".zig",
        });

        const path = try std.fs.path.join(self.allocator, &.{
            "zig-cache",
            "microzig",
            filename,
        });

        if (std.fs.cwd().access(path, .{})) {
            // do nothing, assume existence means it was correctly generated
        } else |_| {
            try std.fs.cwd().makePath(std.fs.path.dirname(path).?);

            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();

            for (self.dependencies.items) |dependency|
                try file.writer().print("pub const {s} = @import(\"{s}\");\n", .{
                    std.zig.fmtId(dependency.name),
                    dependency.name,
                });
        }

        self.generated_file.path = path;
    }
};
