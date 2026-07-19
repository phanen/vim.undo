//! Line-level unified diff between two buffer snapshots.

const std = @import("std");

pub const Op = enum(u8) {
    context = 0,
    delete = 1,
    insert = 2,
};

pub const Line = struct {
    op: Op,
    text: []const u8,
};

pub const Hunk = struct {
    a_start_line: u32,
    a_line_count: u32,
    b_start_line: u32,
    b_line_count: u32,
    lines: []Line,
};

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

pub fn diff(
    alloc: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    a_label: []const u8,
    b_label: []const u8,
    context_line_count: u32,
) Error![]u8 {
    var script = try buildEditScript(alloc, a, b);
    defer script.deinit(alloc);

    const hunks = try buildHunks(alloc, script.items, context_line_count);
    defer {
        for (hunks) |h| alloc.free(h.lines);
        alloc.free(hunks);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("--- {s}\n+++ {s}\n", .{ a_label, b_label });
    for (hunks) |h| {
        try formatHunk(&out.writer, h);
    }
    return out.toOwnedSlice();
}

const ScriptOp = struct {
    op: Op,
    text: []const u8,
};

const EditScript = std.ArrayList(ScriptOp);

/// Build a reverse-time LCS edit script via standard O(n*m) dynamic
/// programming. Returns ops in forward order (oldest -> newest).
fn buildEditScript(
    alloc: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) !EditScript {
    const a_lines_count: u32 = @intCast(a.len);
    const b_lines_count: u32 = @intCast(b.len);
    const width: u32 = b_lines_count + 1;
    const height: u32 = a_lines_count + 1;
    const total: u32 = width * height;

    // Each cell holds an LCS prefix length bounded by min(a, b) lines.
    const dp = try alloc.alloc(u32, total);
    defer alloc.free(dp);
    @memset(dp, 0);

    var i: u32 = 1;
    while (i <= a_lines_count) : (i += 1) {
        var j: u32 = 1;
        while (j <= b_lines_count) : (j += 1) {
            if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
                dp[i * width + j] = dp[(i - 1) * width + (j - 1)] + 1;
            } else {
                dp[i * width + j] = @max(
                    dp[(i - 1) * width + j],
                    dp[i * width + (j - 1)],
                );
            }
        }
    }

    var script: EditScript = .empty;
    errdefer script.deinit(alloc);

    var ai: u32 = a_lines_count;
    var bj: u32 = b_lines_count;
    while (ai > 0 or bj > 0) {
        // Match: walk back diagonally while preserving the LCS prefix.
        if (ai > 0 and bj > 0) {
            if (std.mem.eql(u8, a[ai - 1], b[bj - 1])) {
                try script.append(alloc, .{ .op = .context, .text = a[ai - 1] });
                ai -= 1;
                bj -= 1;
                continue;
            }
        }
        // No shared tail: pick whichever side retains the larger LCS prefix.
        if (bj == 0) {
            try script.append(alloc, .{ .op = .delete, .text = a[ai - 1] });
            ai -= 1;
            continue;
        }
        if (ai == 0) {
            try script.append(alloc, .{ .op = .insert, .text = b[bj - 1] });
            bj -= 1;
            continue;
        }
        if (dp[ai * width + (bj - 1)] >= dp[(ai - 1) * width + bj]) {
            try script.append(alloc, .{ .op = .insert, .text = b[bj - 1] });
            bj -= 1;
        } else {
            try script.append(alloc, .{ .op = .delete, .text = a[ai - 1] });
            ai -= 1;
        }
    }

    std.mem.reverse(ScriptOp, script.items);
    return script;
}

/// Group an edit script into hunks with `context_line_count` lines of
/// leading/trailing unchanged context per hunk. Line counts are 1-indexed
/// (unified diff convention).
fn buildHunks(
    alloc: std.mem.Allocator,
    script: []const ScriptOp,
    context_line_count: u32,
) ![]Hunk {
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer {
        for (hunks.items) |h| alloc.free(h.lines);
        hunks.deinit(alloc);
    }

    var a_line: u32 = 1;
    var b_line: u32 = 1;

    var i: usize = 0;
    while (i < script.len) {
        if (script[i].op == .context) {
            i += 1;
            a_line += 1;
            b_line += 1;
            continue;
        }

        const start = i;
        var end: usize = i;
        while (end < script.len and script[end].op != .context) end += 1;

        var pre: usize = 0;
        while (pre < context_line_count and start >= pre + 1 and
            script[start - pre - 1].op == .context)
        {
            pre += 1;
        }
        var post: usize = 0;
        while (post < context_line_count and end + post < script.len and
            script[end + post].op == .context)
        {
            post += 1;
        }

        const delta: usize = end - start;
        const lines = try alloc.alloc(Line, pre + delta + post);
        errdefer alloc.free(lines);

        var a_count: u32 = 0;
        var b_count: u32 = 0;
        var k: usize = 0;
        while (k < pre) : (k += 1) {
            lines[k] = .{ .op = .context, .text = script[start - pre + k].text };
            a_count += 1;
            b_count += 1;
        }
        var m: usize = 0;
        while (m < delta) : (m += 1) {
            const so = script[start + m];
            lines[pre + m] = .{ .op = so.op, .text = so.text };
            switch (so.op) {
                .delete => a_count += 1,
                .insert => b_count += 1,
                .context => unreachable,
            }
        }
        k = 0;
        while (k < post) : (k += 1) {
            lines[pre + delta + k] = .{ .op = .context, .text = script[end + k].text };
            a_count += 1;
            b_count += 1;
        }

        try hunks.append(alloc, .{
            .a_start_line = a_line - @as(u32, @intCast(pre)),
            .a_line_count = a_count,
            .b_start_line = b_line - @as(u32, @intCast(pre)),
            .b_line_count = b_count,
            .lines = lines,
        });

        const advance: usize = pre + delta + post;
        var j: usize = 0;
        while (j < advance) : (j += 1) {
            const so = script[start - pre + j];
            switch (so.op) {
                .context, .delete => a_line += 1,
                .insert => {},
            }
            switch (so.op) {
                .context, .insert => b_line += 1,
                .delete => {},
            }
        }

        i = end + post;
    }

    return hunks.toOwnedSlice(alloc);
}

fn formatHunk(w: *std.Io.Writer, h: Hunk) Error!void {
    try w.print("@@ -{},{} +{},{} @@\n", .{
        h.a_start_line,
        h.a_line_count,
        h.b_start_line,
        h.b_line_count,
    });
    for (h.lines) |line| {
        const prefix: u8 = switch (line.op) {
            .context => ' ',
            .delete => '-',
            .insert => '+',
        };
        try w.writeByte(prefix);
        try w.writeAll(line.text);
        try w.writeByte('\n');
    }
}

const testing = std.testing;
const allocator = testing.allocator;

test "diff identical inputs emits no hunks" {
    const lines: []const []const u8 = &.{ "a", "b", "c" };
    const out = try diff(allocator, lines, lines, "left.txt", "right.txt", 3);
    defer allocator.free(out);
    try testing.expectEqualStrings("--- left.txt\n+++ right.txt\n", out);
}

test "diff single insertion" {
    const a: []const []const u8 = &.{ "a", "c" };
    const b: []const []const u8 = &.{ "a", "b", "c" };
    const out = try diff(allocator, a, b, "left.txt", "right.txt", 3);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "+b") != null);
}

test "diff single deletion" {
    const a: []const []const u8 = &.{ "a", "b", "c" };
    const b: []const []const u8 = &.{ "a", "c" };
    const out = try diff(allocator, a, b, "left.txt", "right.txt", 3);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "-b") != null);
}

test "diff replaces one line" {
    const a: []const []const u8 = &.{ "x", "y", "z" };
    const b: []const []const u8 = &.{ "x", "Y", "z" };
    const out = try diff(allocator, a, b, "left.txt", "right.txt", 3);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "-y") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+Y") != null);
}
