const std = @import("std");
const vu = @import("vim_undo");

const EXIT_USAGE: u8 = 2;

const SubCmd = enum { list, snap, diff };

const Cli = struct {
    sub: SubCmd,
    undofile: []const u8,
    /// Resolved at parse time when -f or a positional textfile is given.
    /// If empty after parse, the caller tries `autoDetectTextfile` and
    /// errors out if that fails.
    textfile: []const u8,
    label_root: ?[]const u8 = null,
    target_seq: ?u32 = null,
    b_seq: u32 = 0,
    /// True if `textfile` is empty because no -f / positional textfile
    /// was given and the caller still has to attempt auto-detect.
    needs_autodetect: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cli = parseArgs(init.minimal.args) catch |e| switch (e) {
        error.WantHelp => {
            try usage(io);
            return;
        },
        error.ShowUsage => {
            try usage(io);
            std.process.exit(EXIT_USAGE);
        },
        else => die(io, "{s}\n", .{@errorName(e)}),
    };
    var cli_resolved = try resolveTextfile(io, cli);

    const input = try std.Io.Dir.cwd().readFileAlloc(
        io,
        cli_resolved.undofile,
        gpa,
        .limited(64 * 1024 * 1024),
    );
    defer gpa.free(input);
    const fh = try vu.undofile.Parser.parse(gpa, input);
    defer vu.undofile.Parser.deinit(fh, gpa);

    // Diff defaults `a` (target_seq) to seq_last when omitted; this lets
    // `diff undofile b` work like `git diff b`. Snap doesn't take a default.
    if (cli_resolved.sub == .diff and cli_resolved.target_seq == null) {
        cli_resolved.target_seq = fh.seq_last;
    }

    var buf: [1024 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    switch (cli_resolved.sub) {
        .list => try cmdList(&w, fh),
        .snap => try cmdSnap(gpa, io, &w, fh, cli_resolved.target_seq.?, cli_resolved.textfile),
        .diff => try cmdDiff(
            gpa,
            io,
            &w,
            fh,
            cli_resolved.textfile,
            cli_resolved.label_root,
            cli_resolved.target_seq.?,
            cli_resolved.b_seq,
        ),
    }

    std.Io.File.stdout().writeStreamingAll(io, w.buffered()) catch |e| switch (e) {
        error.BrokenPipe => std.process.exit(0),
        else => return e,
    };
}

fn resolveTextfile(io: std.Io, cli: Cli) !Cli {
    if (!cli.needs_autodetect) return cli;
    const detected = autoDetectTextfile(io, cli.undofile) catch |e| switch (e) {
        error.NotFound => return die(io,
            \\snap/diff: missing <textfile>
            \\(use -f <textfile>, or pass as last positional; auto-detect failed)
            \\
        , .{}),
        else => return e,
    };
    var out = cli;
    out.textfile = detected;
    out.needs_autodetect = false;
    return out;
}

const ParseError = error{
    ShowUsage,
    WantHelp,
    MissingSubcommand,
    UnknownSubcommand,
    MissingFlagValue,
    DuplicateFlag,
    TooManyPositionals,
    MissingUndofile,
    InvalidSeq,
    ConflictingTextfile,
};

fn matchArg(a: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, a, short) or std.mem.eql(u8, a, long);
}

fn parseArgs(args: std.process.Args) ParseError!Cli {
    var iter = args.iterate();
    _ = iter.next() orelse return error.ShowUsage;

    // Single pass: scan for --help first; everything else after the subcommand.
    var probe = args.iterate();
    _ = probe.next() orelse return error.MissingSubcommand;
    while (probe.next()) |a| {
        if (matchArg(a, "-h", "--help")) return error.WantHelp;
    }

    const sub_str = iter.next() orelse return error.ShowUsage;
    const sub = std.meta.stringToEnum(SubCmd, sub_str) orelse return error.UnknownSubcommand;

    var textfile: ?[]const u8 = null;
    var label_root: ?[]const u8 = null;
    var positional_buf: [4][]const u8 = undefined;
    var positional_count: usize = 0;

    while (iter.next()) |a| {
        if (matchArg(a, "-f", "--file")) {
            const p = iter.next() orelse return error.MissingFlagValue;
            if (textfile != null) return error.DuplicateFlag;
            textfile = p;
            continue;
        }
        if (matchArg(a, "-L", "--label-root")) {
            const p = iter.next() orelse return error.MissingFlagValue;
            if (label_root != null) return error.DuplicateFlag;
            label_root = p;
            continue;
        }
        if (positional_count >= positional_buf.len) return error.TooManyPositionals;
        positional_buf[positional_count] = a;
        positional_count += 1;
    }

    return switch (sub) {
        .list => finalizeList(positional_buf[0..positional_count], textfile, label_root),
        .snap => finalizeSnap(positional_buf[0..positional_count], &textfile, label_root),
        .diff => finalizeDiff(positional_buf[0..positional_count], &textfile, label_root),
    };
}

fn finalizeList(
    positional: []const []const u8,
    textfile: ?[]const u8,
    label_root: ?[]const u8,
) ParseError!Cli {
    if (positional.len != 1) return error.MissingUndofile;
    if (textfile != null) return error.ConflictingTextfile;
    if (label_root != null) return error.ConflictingTextfile;
    return .{
        .sub = .list,
        .undofile = positional[0],
        .textfile = "",
    };
}

fn finalizeSnap(
    positional: []const []const u8,
    textfile: *?[]const u8,
    label_root: ?[]const u8,
) ParseError!Cli {
    if (positional.len < 1) return error.MissingUndofile;
    var seq: ?u32 = null;
    if (positional.len >= 2) {
        seq = std.fmt.parseInt(u32, positional[1], 10) catch return error.InvalidSeq;
    }
    if (positional.len >= 3) {
        if (textfile.* != null) return error.ConflictingTextfile;
        textfile.* = positional[2];
    }
    const resolved = textfile.*;
    return .{
        .sub = .snap,
        .undofile = positional[0],
        .textfile = resolved orelse "",
        .label_root = label_root,
        .target_seq = seq,
        .needs_autodetect = resolved == null,
    };
}

fn finalizeDiff(
    positional: []const []const u8,
    textfile: *?[]const u8,
    label_root: ?[]const u8,
) ParseError!Cli {
    if (positional.len < 2) return error.MissingUndofile;
    const undofile = positional[0];
    const b_seq = std.fmt.parseInt(u32, positional[1], 10) catch return error.InvalidSeq;

    var a_seq: ?u32 = null;
    if (positional.len >= 3) {
        // Positional 2 is either an integer <a> or the textfile path; the
        // integer test disambiguates. If -f already set textfile, positional
        // 2 must be <a>.
        if (textfile.* != null) {
            a_seq = std.fmt.parseInt(u32, positional[2], 10) catch return error.InvalidSeq;
            if (positional.len >= 4) return error.ConflictingTextfile;
        } else if (std.fmt.parseInt(u32, positional[2], 10)) |v| {
            a_seq = v;
            if (positional.len >= 4) textfile.* = positional[3];
        } else |_| {
            textfile.* = positional[2];
        }
    }
    const resolved = textfile.*;
    return .{
        .sub = .diff,
        .undofile = undofile,
        .textfile = resolved orelse "",
        .label_root = label_root,
        .target_seq = a_seq,
        .b_seq = b_seq,
        .needs_autodetect = resolved == null,
    };
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print(fmt, args);
    try std.Io.File.stderr().writeStreamingAll(io, w.buffered());
}

fn die(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    stderrPrint(io, fmt, args) catch {};
    std.process.exit(EXIT_USAGE);
}

/// Returns the directory basename + sub-path so `patch -p1` can strip the
/// synthetic prefix. With no root, returns `text_path` unchanged.
const LabelError = error{ LabelRootNotPrefix, OutOfMemory };

fn buildLabel(
    alloc: std.mem.Allocator,
    text_path: []const u8,
    label_root: ?[]const u8,
) LabelError![]const u8 {
    const root = label_root orelse return text_path;
    if (!std.mem.startsWith(u8, text_path, root)) return error.LabelRootNotPrefix;
    const after = text_path[root.len..];
    const suffix = if (std.mem.startsWith(u8, after, "/")) after[1..] else after;
    const root_basename = std.fs.path.basename(root);
    const out = try alloc.alloc(u8, root_basename.len + 1 + suffix.len);
    @memcpy(out[0..root_basename.len], root_basename);
    out[root_basename.len] = '/';
    @memcpy(out[root_basename.len + 1 ..][0..suffix.len], suffix);
    return out;
}

fn tryDotfileCandidate(io: std.Io, dir: []const u8, base: []const u8) ?[]const u8 {
    if (base.len == 0) return null;
    if (base[0] != '.') return null;
    const candidate_len = dir.len + 1 + (base.len - 1);
    if (candidate_len > std.fs.max_path_bytes) return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '/';
    @memcpy(buf[dir.len + 1 ..][0 .. base.len - 1], base[1..]);
    if (std.Io.Dir.cwd().statFile(io, buf[0..candidate_len], .{})) |_| {
        return buf[0..candidate_len];
    } else |_| return null;
}

fn tryPercentDecodedCandidate(io: std.Io, encoded: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var n: usize = 0;
    for (encoded) |c| {
        buf[n] = if (c == '%') '/' else c;
        n += 1;
    }
    if (n > buf.len) return null;
    if (std.Io.Dir.cwd().statFile(io, buf[0..n], .{})) |_| {
        return buf[0..n];
    } else |_| return null;
}

fn autoDetectTextfile(io: std.Io, undofile: []const u8) ![]const u8 {
    const alloc = std.heap.page_allocator;

    if (std.mem.endsWith(u8, undofile, ".un~")) {
        const without = undofile[0 .. undofile.len - ".un~".len];
        const last_sep = std.mem.lastIndexOfScalar(u8, without, '/') orelse 0;
        if (tryDotfileCandidate(io, without[0..last_sep], without[last_sep..])) |candidate| {
            return try alloc.dupe(u8, candidate);
        }
    }

    if (std.mem.lastIndexOfScalar(u8, undofile, '/')) |last_sep| {
        const encoded = undofile[last_sep + 1 ..];
        if (std.mem.indexOfScalar(u8, encoded, '%') != null) {
            if (!std.mem.endsWith(u8, undofile, ".un~")) {
                if (tryPercentDecodedCandidate(io, encoded)) |candidate| {
                    return try alloc.dupe(u8, candidate);
                }
            }
        }
    }

    return error.NotFound;
}

fn readLines(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(data);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| alloc.free(line);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        // `splitScalar` emits a synthetic empty slice after a trailing '\n'.
        // Drop only that trailing empty; empty interior lines are kept.
        if (line.len == 0) {
            if (it.peek() == null) break;
        }
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
                i, e.top_line, e.bot_line, e.lcount, e.size,
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
    text_path: []const u8,
    label_root: ?[]const u8,
    a_seq: u32,
    b_seq: u32,
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

    const rel = buildLabel(alloc, text_path, label_root) catch |e| {
        try w.print("error: {s}\n", .{@errorName(e)});
        return;
    };
    defer if (label_root != null) alloc.free(rel);

    const out = try vu.diff.diff(alloc, a.lines, b.lines, rel, rel, 3);
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
        \\If -f is omitted, vim-undo tries to recover the path from the
        \\undofile name itself: 'undodir == "."' produces ".foo.un~"
        \\next to the file; otherwise Neovim percent-encodes path
        \\separators (see src/nvim/undo.c:u_get_undo_file_name) and we
        \\decode them. Auto-detect only works if the original file
        \\still exists at the decoded path. Use -f when it has been
        \\moved or renamed.
        \\
        \\Diff labels are the absolute path of <textfile> by default, so diff
        \\viewers like delta show the full path. To make the diff apply
        \\with 'patch -Np1 -i -', pass -L <dir> where <dir> is the
        \\directory the user will 'cd' into before applying: vim-undo
        \\emits '<dir basename>/<textfile relative to <dir>>' and patch
        \\-p1 strips the synthetic prefix. GNU patch refuses absolute
        \\paths as 'dangerous', so absolute labels are display-only.
        \\
        \\flags:
        \\  -f, --file <path>   textfile (or pass as last positional)
        \\  -L, --label-root <dir>  emit '<dir basename>/<rel>' for patch -p1
        \\  -h, --help          show this help
        \\
    , .{});
}

test "autoDetectTextfile: rejects bogus percent-encoded path" {
    try std.testing.expectError(
        error.NotFound,
        autoDetectTextfile(std.testing.io, "/nonexistent/%foo%bar"),
    );
}

test "buildLabel: bare path passes through unchanged" {
    const out = try buildLabel(std.testing.allocator, "/abs/path/foo.txt", null);
    try std.testing.expectEqualStrings("/abs/path/foo.txt", out);
}

test "buildLabel: with root emits '<root>/<relative>'" {
    const out = try buildLabel(std.testing.allocator, "/proj/sub/foo.txt", "/proj");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("proj/sub/foo.txt", out);
}

test "buildLabel: rejects root that is not a prefix" {
    try std.testing.expectError(
        error.LabelRootNotPrefix,
        buildLabel(std.testing.allocator, "/proj/foo.txt", "/elsewhere"),
    );
}
