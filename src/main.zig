const std = @import("std");
const vu = @import("vim_undo");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next() orelse {
        try usage(io);
        return;
    };
    const path = args.next() orelse {
        try usage(io);
        std.process.exit(2);
    };
    const sub = args.next() orelse {
        try usage(io);
        std.process.exit(2);
    };

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(input);
    const fh = try vu.undofile.Parser.parse(gpa, input);
    defer vu.undofile.Parser.deinit(fh, gpa);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    if (std.mem.eql(u8, sub, "list")) {
        try cmdList(&w, fh);
    } else if (std.mem.eql(u8, sub, "snap")) {
        const seq_str = args.next() orelse {
            try stderrPrint(io, "snap: missing <seq> <textfile>\n", .{});
            std.process.exit(2);
        };
        const seq = try std.fmt.parseInt(u32, seq_str, 10);
        const text_path = args.next() orelse {
            try stderrPrint(io, "snap: missing <textfile> (the buffer the undofile was written for)\n", .{});
            std.process.exit(2);
        };
        try cmdSnap(gpa, io, &w, fh, seq, text_path);
    } else if (std.mem.eql(u8, sub, "diff")) {
        const a_str = args.next() orelse {
            try stderrPrint(io, "diff: missing <seqA> <seqB> <textfile>\n", .{});
            std.process.exit(2);
        };
        const b_str = args.next() orelse {
            try stderrPrint(io, "diff: missing <seqB> <textfile>\n", .{});
            std.process.exit(2);
        };
        const a = try std.fmt.parseInt(u32, a_str, 10);
        const b = try std.fmt.parseInt(u32, b_str, 10);
        const text_path = args.next() orelse {
            try stderrPrint(io, "diff: missing <textfile>\n", .{});
            std.process.exit(2);
        };
        try cmdDiff(gpa, io, &w, fh, a, b, text_path);
    } else {
        try stderrPrint(io, "unknown subcommand: {s}\n", .{sub});
        std.process.exit(2);
    }

    try std.Io.File.stdout().writeStreamingAll(io, w.buffered());
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
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
        try w.print("error snapshotAt({d}): {s}\n", .{ b_seq, @errorName(e) });
        return;
    };
    defer vu.replay.deinit(b, alloc);

    const out = try vu.diff.diff(alloc, a.lines, b.lines, 3);
    defer alloc.free(out);
    try w.writeAll(out);
}

fn usage(io: std.Io) !void {
    try stderrPrint(io,
        \\usage: vim-undo <undofile> <subcommand> [args]
        \\
        \\subcommands:
        \\  list                       list all undo headers
        \\  snap <seq> <textfile>      print buffer state at <seq>
        \\  diff <a> <b> <textfile>    unified diff from <a> to <b>
        \\
        \\<textfile> is the buffer content the .un~ was written for; it is
        \\needed to reconstruct leaves reachable from the redo chain.
        \\
    , .{});
}