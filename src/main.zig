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

    if (std.mem.eql(u8, sub, "list")) {
        try cmdList(io, gpa, fh);
    } else if (std.mem.eql(u8, sub, "snap")) {
        const seq_str = args.next() orelse {
            try stderrPrint(io, "snap: missing <seq>\n", .{});
            std.process.exit(2);
        };
        const seq = try std.fmt.parseInt(u32, seq_str, 10);
        try cmdSnap(io, gpa, fh, seq);
    } else if (std.mem.eql(u8, sub, "diff")) {
        const a_str = args.next() orelse {
            try stderrPrint(io, "diff: missing <seqA> <seqB>\n", .{});
            std.process.exit(2);
        };
        const b_str = args.next() orelse {
            try stderrPrint(io, "diff: missing <seqB>\n", .{});
            std.process.exit(2);
        };
        const a = try std.fmt.parseInt(u32, a_str, 10);
        const b = try std.fmt.parseInt(u32, b_str, 10);
        try cmdDiff(io, gpa, fh, a, b);
    } else {
        try stderrPrint(io, "unknown subcommand: {s}\n", .{sub});
        std.process.exit(2);
    }
}

fn usage(io: std.Io) !void {
    try stderrPrint(io,
        \\usage: vim-undo <undofile> <subcommand> [args]
        \\
        \\subcommands:
        \\  list               list all undo headers
        \\  snap <seq>         print buffer state at <seq>
        \\  diff <a> <b>       unified diff from <a> to <b>
        \\
    , .{});
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print(fmt, args);
    try std.Io.File.stderr().writeStreamingAll(io, w.buffered());
}

fn stdoutWriter(io: std.Io) std.Io.File.Writer {
    var buf: [4096]u8 = undefined;
    return std.Io.File.stdout().writer(io, &buf);
}

fn cmdList(io: std.Io, alloc: std.mem.Allocator, fh: vu.undofile.FileHeader) !void {
    var w = stdoutWriter(io);
    defer w.interface.flush() catch {};

    try w.interface.print("headers: {d}  numhead: {d}  seq_last: {d}  seq_cur: {d}\n", .{
        fh.headers.len, fh.numhead, fh.seq_last, fh.seq_cur,
    });
    for (fh.headers) |h| {
        try w.interface.print("  seq={d} prev={d} next={d} alt_prev={d} alt_next={d} entries={d}\n", .{
            h.seq, h.prev_seq, h.next_seq, h.alt_prev_seq, h.alt_next_seq, h.entries.len,
        });
        for (h.entries, 0..) |e, i| {
            try w.interface.print("    [{d}] top={d} bot={d} lcount={d} size={d}\n", .{
                i, e.top, e.bot, e.lcount, e.size,
            });
        }
    }
    _ = alloc;
}

fn cmdSnap(io: std.Io, alloc: std.mem.Allocator, fh: vu.undofile.FileHeader, seq: u32) !void {
    var w = stdoutWriter(io);
    defer w.interface.flush() catch {};

    const state = vu.replay.snapshotAt(alloc, &fh, seq) catch |e| {
        try w.interface.print("error: {s}\n", .{@errorName(e)});
        return;
    };
    defer vu.replay.deinit(state, alloc);
    for (state.lines) |line| {
        try w.interface.print("{s}\n", .{line});
    }
}

fn cmdDiff(
    io: std.Io,
    alloc: std.mem.Allocator,
    fh: vu.undofile.FileHeader,
    a_seq: u32,
    b_seq: u32,
) !void {
    var w = stdoutWriter(io);
    defer w.interface.flush() catch {};

    const a = vu.replay.snapshotAt(alloc, &fh, a_seq) catch |e| {
        try w.interface.print("error snapshotAt({d}): {s}\n", .{ a_seq, @errorName(e) });
        return;
    };
    defer vu.replay.deinit(a, alloc);
    const b = vu.replay.snapshotAt(alloc, &fh, b_seq) catch |e| {
        try w.interface.print("error snapshotAt({d}): {s}\n", .{ b_seq, @errorName(e) });
        return;
    };
    defer vu.replay.deinit(b, alloc);

    const out = try vu.diff.diff(alloc, a.lines, b.lines, 3);
    defer alloc.free(out);
    try w.interface.writeAll(out);
}
