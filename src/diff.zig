//! Line-level unified diff between two BufferState snapshots.
//!
//! Uses an O(N*M) LCS dynamic-programming table — the undo tree's
//! snapshot sizes are tiny (<1k lines), so the constant factor matters
//! more than asymptotic complexity.

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
    a_start: usize,
    a_count: usize,
    b_start: usize,
    b_count: usize,
    lines: []Line,
};

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

pub fn diff(
    alloc: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    context: usize,
) Error![]u8 {
    var script = try buildEditScript(alloc, a, b);
    defer script.deinit(alloc);

    const hunks = try buildHunks(alloc, script.items, a.len, b.len, context);
    defer {
        for (hunks) |h| alloc.free(h.lines);
        alloc.free(hunks);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("--- a\n+++ b\n", .{});
    for (hunks) |h| {
        try formatHunk(&out.writer, h);
    }
    const result = try out.toOwnedSlice();
    return result;
}

const ScriptOp = struct {
    op: Op,
    text: []const u8,
};

const EditScript = std.ArrayList(ScriptOp);

fn buildEditScript(alloc: std.mem.Allocator, a: []const []const u8, b: []const []const u8) !EditScript {
    const na = a.len;
    const nb = b.len;
    const width = nb + 1;
    const height = na + 1;
    const total = width * height;

    const dp = try alloc.alloc(usize, total);
    defer alloc.free(dp);
    @memset(dp, 0);

    var i: usize = 1;
    while (i <= na) : (i += 1) {
        var j: usize = 1;
        while (j <= nb) : (j += 1) {
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

    var ai: usize = na;
    var bj: usize = nb;
    while (ai > 0 or bj > 0) {
        if (ai > 0 and bj > 0 and std.mem.eql(u8, a[ai - 1], b[bj - 1])) {
            try script.append(alloc, .{ .op = .context, .text = a[ai - 1] });
            ai -= 1;
            bj -= 1;
        } else if (bj > 0 and (ai == 0 or dp[ai * width + (bj - 1)] >= dp[(ai - 1) * width + bj])) {
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

fn buildHunks(
    alloc: std.mem.Allocator,
    script: []const ScriptOp,
    na: usize,
    nb: usize,
    context: usize,
) ![]Hunk {
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer {
        for (hunks.items) |h| alloc.free(h.lines);
        hunks.deinit(alloc);
    }

    var a_idx: usize = 1;
    var b_idx: usize = 1;

    var i: usize = 0;
    while (i < script.len) {
        if (script[i].op == .context) {
            i += 1;
            a_idx += 1;
            b_idx += 1;
            continue;
        }

        const start: usize = i;
        var end: usize = i;
        while (end < script.len and script[end].op != .context) end += 1;

        var pre: usize = 0;
        while (pre < context and start >= pre + 1 and script[start - pre - 1].op == .context) {
            pre += 1;
        }
        var post: usize = 0;
        while (post < context and end + post < script.len and script[end + post].op == .context) {
            post += 1;
        }

        var a_count: usize = 0;
        var b_count: usize = 0;
        var lines: std.ArrayList(Line) = .empty;
        var owned_lines: ?[]Line = null;
        errdefer if (owned_lines) |s| alloc.free(s);

        var k: usize = 0;
        while (k < pre) : (k += 1) {
            try lines.append(alloc, .{ .op = .context, .text = script[start - pre + k].text });
            a_count += 1;
            b_count += 1;
        }
        k = 0;
        while (k < end - start) : (k += 1) {
            const so = script[start + k];
            try lines.append(alloc, .{ .op = so.op, .text = so.text });
            switch (so.op) {
                .delete => a_count += 1,
                .insert => b_count += 1,
                .context => unreachable,
            }
        }
        k = 0;
        while (k < post) : (k += 1) {
            try lines.append(alloc, .{ .op = .context, .text = script[end + k].text });
            a_count += 1;
            b_count += 1;
        }

        owned_lines = try lines.toOwnedSlice(alloc);

        const a_start = a_idx - pre;
        const b_start = b_idx - pre;

        try hunks.append(alloc, .{
            .a_start = a_start,
            .a_count = a_count,
            .b_start = b_start,
            .b_count = b_count,
            .lines = owned_lines.?,
        });
        owned_lines = null;

        var j: usize = 0;
        while (j < pre + (end - start) + post) : (j += 1) {
            const so = script[start - pre + j];
            switch (so.op) {
                .context, .delete => a_idx += 1,
                .insert => {},
            }
            switch (so.op) {
                .context, .insert => b_idx += 1,
                .delete => {},
            }
        }

        i = end + post;
    }

    _ = na;
    _ = nb;
    return hunks.toOwnedSlice(alloc);
}

fn formatHunk(w: *std.Io.Writer, h: Hunk) Error!void {
    try w.print("@@ -{} +{} @@\n", .{ h.a_start, h.b_start });
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
    const out = try diff(allocator, lines, lines, 3);
    defer allocator.free(out);
    try testing.expectEqualStrings("--- a\n+++ b\n", out);
}

test "diff single insertion" {
    const a: []const []const u8 = &.{ "a", "c" };
    const b: []const []const u8 = &.{ "a", "b", "c" };
    const out = try diff(allocator, a, b, 3);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "+b") != null);
}

test "diff single deletion" {
    const a: []const []const u8 = &.{ "a", "b", "c" };
    const b: []const []const u8 = &.{ "a", "c" };
    const out = try diff(allocator, a, b, 3);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "-b") != null);
}

test "diff replaces one line" {
    const a: []const []const u8 = &.{ "x", "y", "z" };
    const b: []const []const u8 = &.{ "x", "Y", "z" };
    const out = try diff(allocator, a, b, 3);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "-y") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+Y") != null);
}