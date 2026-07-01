const std = @import("std");
const vu = @import("vim_undo");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const stderr = std.Io.File.stderr();

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next() orelse {
        try stderr.writeStreamingAll(io, "usage: vim-undo <undofile> [seq1 seq2]\n");
        return;
    };

    const path = args_iter.next() orelse {
        try stderr.writeStreamingAll(io, "missing undofile path\n");
        std.process.exit(1);
    };

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(input);

    const fh = try vu.undofile.Parser.parse(gpa, input);
    defer vu.undofile.Parser.deinit(fh, gpa);

    const stdout = std.Io.File.stdout();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("headers: {d}, numhead: {d}, seq_last: {d}, seq_cur: {d}\n", .{
        fh.headers.len,
        fh.numhead,
        fh.seq_last,
        fh.seq_cur,
    });
    try stdout.writeStreamingAll(io, w.buffered());

    for (fh.headers) |h| {
        var buf2: [512]u8 = undefined;
        var w2: std.Io.Writer = .fixed(&buf2);
        try w2.print("  seq={d} prev={d} next={d} alt_prev={d} alt_next={d} entries={d} time={d}\n", .{
            h.seq,
            h.prev_seq,
            h.next_seq,
            h.alt_prev_seq,
            h.alt_next_seq,
            h.entries.len,
            h.time,
        });
        try stdout.writeStreamingAll(io, w2.buffered());

        for (h.entries, 0..) |e, i| {
            var buf3: [256]u8 = undefined;
            var w3: std.Io.Writer = .fixed(&buf3);
            try w3.print("    [{d}] top={d} bot={d} lcount={d} size={d} lines=\n", .{
                i,
                e.top,
                e.bot,
                e.lcount,
                e.size,
            });
            try stdout.writeStreamingAll(io, w3.buffered());
            for (e.lines) |line| {
                try stdout.writeStreamingAll(io, line.bytes);
                try stdout.writeStreamingAll(io, "\n");
            }
        }
    }
}