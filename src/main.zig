const std = @import("std");
const vu = @import("vim_undo");

const SubCmd = enum { list, snap, diff };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next() orelse {
        try usage(io);
        return;
    };
    while (args_iter.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try usage(io);
            return;
        }
    }
    args_iter = init.minimal.args.iterate();
    _ = args_iter.next() orelse {
        try usage(io);
        return;
    };
    const sub_str = args_iter.next() orelse {
        try usage(io);
        std.process.exit(2);
    };
    const sub: SubCmd = std.meta.stringToEnum(SubCmd, sub_str) orelse {
        try stderrPrint(io, "unknown subcommand: {s}\n", .{sub_str});
        try usage(io);
        std.process.exit(2);
    };

    var undofile: ?[]const u8 = null;
    var textfile: ?[]const u8 = null;
    var seq: ?u32 = null;
    var a_seq: ?u32 = null;
    var b_seq: ?u32 = null;
    var positional: [4][]const u8 = undefined;
    var positional_n: usize = 0;

    while (args_iter.next()) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
            const p = args_iter.next() orelse {
                try stderrPrint(io, "{s}: -f requires a path argument\n", .{sub_str});
                std.process.exit(2);
            };
            if (textfile != null) {
                try stderrPrint(io, "{s}: -f given twice\n", .{sub_str});
                std.process.exit(2);
            }
            textfile = p;
            continue;
        }
        if (positional_n >= positional.len) {
            try stderrPrint(io, "{s}: too many positional arguments\n", .{sub_str});
            std.process.exit(2);
        }
        positional[positional_n] = a;
        positional_n += 1;
    }

    switch (sub) {
        .list => {
            if (positional_n < 1) {
                try stderrPrint(io, "list: missing <undofile>\n", .{});
                std.process.exit(2);
            }
            if (positional_n > 1 or textfile != null or seq != null or a_seq != null or b_seq != null) {
                try stderrPrint(io, "list: takes no arguments other than <undofile>\n", .{});
                std.process.exit(2);
            }
            undofile = positional[0];
        },
        .snap => {
            if (positional_n < 1) {
                try stderrPrint(io, "snap: missing <undofile>\n", .{});
                std.process.exit(2);
            }
            undofile = positional[0];
            if (positional_n >= 2) {
                seq = std.fmt.parseInt(u32, positional[1], 10) catch {
                    try stderrPrint(io, "snap: <seq> must be an integer, got: {s}\n", .{positional[1]});
                    std.process.exit(2);
                };
            }
            if (positional_n >= 3) {
                if (textfile != null) {
                    try stderrPrint(io, "snap: textfile given twice\n", .{});
                    std.process.exit(2);
                }
                textfile = positional[2];
            }
            if (textfile == null) {
                try stderrPrint(io, "snap: missing <textfile> (use -f <textfile> or pass as last positional)\n", .{});
                std.process.exit(2);
            }
        },
        .diff => {
            if (positional_n < 2) {
                try stderrPrint(io, "diff: missing <undofile> <b>\n", .{});
                std.process.exit(2);
            }
            undofile = positional[0];
            b_seq = std.fmt.parseInt(u32, positional[1], 10) catch {
                try stderrPrint(io, "diff: <b> must be an integer, got: {s}\n", .{positional[1]});
                std.process.exit(2);
            };
            if (positional_n >= 3) {
                a_seq = std.fmt.parseInt(u32, positional[2], 10) catch {
                    try stderrPrint(io, "diff: <a> must be an integer, got: {s}\n", .{positional[2]});
                    std.process.exit(2);
                };
            }
            if (positional_n >= 4) {
                if (textfile != null) {
                    try stderrPrint(io, "diff: textfile given twice\n", .{});
                    std.process.exit(2);
                }
                textfile = positional[3];
            }
            if (textfile == null) {
                try stderrPrint(io, "diff: missing <textfile> (use -f <textfile> or pass as last positional)\n", .{});
                std.process.exit(2);
            }
        },
    }

    const input = try std.Io.Dir.cwd().readFileAlloc(io, undofile.?, gpa, .unlimited);
    defer gpa.free(input);
    const fh = try vu.undofile.Parser.parse(gpa, input);
    defer vu.undofile.Parser.deinit(fh, gpa);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    switch (sub) {
        .list => try cmdList(&w, fh),
        .snap => {
            const target = seq orelse fh.seq_last;
            try cmdSnap(gpa, io, &w, fh, target, textfile.?);
        },
        .diff => {
            const a = a_seq orelse fh.seq_last;
            try cmdDiff(gpa, io, &w, fh, a, b_seq.?, textfile.?);
        },
    }

    try std.Io.File.stdout().writeStreamingAll(io, w.buffered());
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print(fmt, args);
    try std.Io.File.stderr().writeStreamingAll(io, w.buffered());
}

fn readLines(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(data);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| alloc.free(line);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        const owned = try alloc.dupe(u8, line);
        errdefer alloc.free(owned);
        try out.append(alloc, owned);
    }
    return out.toOwnedSlice(alloc);
}

fn cmdList(w: *std.Io.Writer, fh: vu.undofile.FileHeader) !void {
    try w.print("headers: {d}  numhead: {d}  seq_last: {d}  seq_cur: {d}\n", .{
        fh.headers.len, fh.numhead, fh.seq_last, fh.seq_cur,
    });
    for (fh.headers) |h| {
        try w.print("  seq={d} prev={d} next={d} alt_prev={d} alt_next={d} entries={d}\n", .{
            h.seq, h.prev_seq, h.next_seq, h.alt_prev_seq, h.alt_next_seq, h.entries.len,
        });
        for (h.entries, 0..) |e, i| {
            try w.print("    [{d}] top={d} bot={d} lcount={d} size={d}\n", .{
                i, e.top, e.bot, e.lcount, e.size,
            });
        }
    }
}

fn cmdSnap(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    fh: vu.undofile.FileHeader,
    seq: u32,
    text_path: []const u8,
) !void {
    const initial = readLines(alloc, io, text_path) catch |e| {
        try w.print("error reading {s}: {s}\n", .{ text_path, @errorName(e) });
        return;
    };
    defer {
        for (initial) |line| alloc.free(line);
        alloc.free(initial);
    }

    const state = vu.replay.snapshotAt(alloc, initial, &fh, seq) catch |e| {
        try w.print("error: {s}\n", .{@errorName(e)});
        return;
    };
    defer vu.replay.deinit(state, alloc);
    for (state.lines) |line| {
        try w.print("{s}\n", .{line});
    }
}

fn cmdDiff(
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    fh: vu.undofile.FileHeader,
    a_seq: u32,
    b_seq: u32,
    text_path: []const u8,
) !void {
    const initial = readLines(alloc, io, text_path) catch |e| {
        try w.print("error reading {s}: {s}\n", .{ text_path, @errorName(e) });
        return;
    };
    defer {
        for (initial) |line| alloc.free(line);
        alloc.free(initial);
    }

    const a = vu.replay.snapshotAt(alloc, initial, &fh, a_seq) catch |e| {
        try w.print("error snapshotAt({d}): {s}\n", .{ a_seq, @errorName(e) });
        return;
    };
    defer vu.replay.deinit(a, alloc);
    const b = vu.replay.snapshotAt(alloc, initial, &fh, b_seq) catch |e| {
        try w.print("error snapshotAt({d}): {s}\n", .{ b_seq, @errorName(e)});
        return;
    };
    defer vu.replay.deinit(b, alloc);

    const out = try vu.diff.diff(alloc, a.lines, b.lines, 3);
    defer alloc.free(out);
    try w.writeAll(out);
}

fn usage(io: std.Io) !void {
    try stderrPrint(io,
        \\usage: vim-undo <subcommand> <undofile> [args] [-f <textfile>]
        \\
        \\subcommands:
        \\  list <undofile>
        \\  snap <undofile> [<seq>] [-f <textfile>]
        \\  diff <undofile> <b> [-f <textfile>]
        \\  diff <undofile> <a> <b> [-f <textfile>]
        \\
        \\<textfile> is the buffer content the .un~ was written for.
        \\It is REQUIRED for snap and diff, because the newhead's state
        \\(the saved file at write time) is not stored in the .un~.
        \\Pass it via -f or as the last positional argument.
        \\
        \\flags:
        \\  -f, --file <path>   textfile (or pass as last positional)
        \\  -h, --help          show this help
        \\
    , .{});
}