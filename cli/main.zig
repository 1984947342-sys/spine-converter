const std = @import("std");
const Io = std.Io;
const sc = @import("spine_converter");

const usage =
    \\usage: spine-converter <command> [args]
    \\
    \\commands:
    \\  detect <file>...                  print format and Spine version
    \\  convert <input> <output> [flags]  convert skeleton data or an atlas
    \\  version                           print the converter version
    \\
    \\convert flags:
    \\  --to <version>    target version such as 4.3 or 3.8.99
    \\  --json, --binary  target format, default keeps the source format, not for atlases
    \\  --pretty          indent JSON output
    \\  --fail-on-loss    fail instead of dropping or approximating data
    \\  --no-rewrite      keep the source structure where a rewrite would pose exactly
    \\  --atlas <file>    atlas of a 3.5 or 3.6 skeleton, keeps mesh UVs of stripped regions
    \\
    \\exit status: 0 exact, 1 error, 2 usage, 3 written with losses
    \\
;

const Cli = struct {
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    err: *Io.Writer,

    fn detect(cli: Cli, paths: []const []const u8) !u8 {
        if (paths.len == 0) return cli.usageError();
        var failed = false;
        for (paths) |path| {
            const data = cli.read(cli.gpa, path) orelse {
                failed = true;
                continue;
            };
            defer cli.gpa.free(data);
            const detected = sc.detect(data) catch {
                try cli.out.print("{s}\tunknown\n", .{path});
                failed = true;
                continue;
            };
            const version = if (detected.version) |*v| v.text() else "-";
            try cli.out.print("{s}\t{t}\t{s}\n", .{ path, detected.format, version });
        }
        return if (failed) 1 else 0;
    }

    fn convert(cli: Cli, args: []const []const u8) !u8 {
        var paths: [2][]const u8 = undefined;
        var path_count: usize = 0;
        var options: sc.convert.Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--to")) {
                i += 1;
                if (i == args.len) return cli.usageError();
                options.target_version = sc.Version.parse(args[i]) orelse {
                    try cli.err.print("invalid version: {s}\n", .{args[i]});
                    return 2;
                };
            } else if (std.mem.eql(u8, arg, "--json")) {
                options.target_format = .json;
            } else if (std.mem.eql(u8, arg, "--binary")) {
                options.target_format = .binary;
            } else if (std.mem.eql(u8, arg, "--pretty")) {
                options.pretty_json = true;
            } else if (std.mem.eql(u8, arg, "--fail-on-loss")) {
                options.fail_on_loss = true;
            } else if (std.mem.eql(u8, arg, "--no-rewrite")) {
                options.rewrite = false;
            } else if (std.mem.eql(u8, arg, "--atlas")) {
                i += 1;
                if (i == args.len) return cli.usageError();
                options.atlas = cli.read(cli.arena, args[i]) orelse return 1;
            } else if (path_count < paths.len and !std.mem.startsWith(u8, arg, "--")) {
                paths[path_count] = arg;
                path_count += 1;
            } else return cli.usageError();
        }
        if (path_count != 2) return cli.usageError();

        const data = cli.read(cli.arena, paths[0]) orelse return 1;
        var report: sc.Report = .{ .arena = cli.arena };
        const output = sc.convert.convert(cli.arena, data, options, &report);
        for (report.entries.items) |e| {
            try cli.err.print("{t}\t{t}\t{t}\t{s}\t{s}\t{t}\n", .{ e.code.severity(), e.code.impact(), e.code, e.path, e.message, e.remedy });
        }
        const losses = report.lossCount();
        if (losses != 0) {
            const noun = if (losses == 1) "loss" else "losses";
            try cli.err.print("{d} {s}, most severe impact {t}", .{ losses, noun, report.maxImpact() });
            const rewritable = report.remedyCount(.rewrite);
            if (rewritable != 0) try cli.err.print(", {d} exact without --no-rewrite", .{rewritable});
            const runtime = report.remedyCount(.runtime);
            if (runtime != 0) try cli.err.print(", {d} need a runtime patch or rig change", .{runtime});
            try cli.err.print("\n", .{});
        }
        const result = output catch |e| {
            try cli.err.print("{s}: {t}\n", .{ paths[0], e });
            return 1;
        };
        Io.Dir.cwd().writeFile(cli.io, .{ .sub_path = paths[1], .data = result.data }) catch |e| {
            try cli.err.print("{s}: {t}\n", .{ paths[1], e });
            return 1;
        };
        return if (losses != 0) 3 else 0;
    }

    fn read(cli: Cli, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
        return Io.Dir.cwd().readFileAlloc(cli.io, path, allocator, .unlimited) catch |e| {
            cli.err.print("{s}: {t}\n", .{ path, e }) catch {};
            return null;
        };
    }

    fn usageError(cli: Cli) !u8 {
        try cli.err.writeAll(usage);
        return 2;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    defer stdout_writer.interface.flush() catch {};
    defer stderr_writer.interface.flush() catch {};

    const cli: Cli = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = arena,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
    };
    if (args.len < 2) return cli.usageError();
    const command = args[1];
    if (std.mem.eql(u8, command, "detect")) return cli.detect(args[2..]);
    if (std.mem.eql(u8, command, "convert")) return cli.convert(args[2..]);
    if (std.mem.eql(u8, command, "version")) {
        try cli.out.print("{s}\n", .{sc.library_version});
        return 0;
    }
    return cli.usageError();
}
