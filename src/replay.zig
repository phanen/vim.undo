//! Replay Neovim's undo/redo entry chain into a concrete buffer state.
//!
//! `snapshotAt` reconstructs the buffer at the time of a given header by
//! starting from the saved file content (= buffer state right after the
//! newhead edit) and applying `u_undoredo` walks for every header between
//! the newhead and the target along the linear `uh_next` chain (which
//! points toward older states).
//!
//! Each `u_entry` records (top, bot, size, lines) where `lines` is the
//! PRE-change content of the affected region; `u_undoredo` always
//! applies entries as undo (POST -> PRE), so replaying back from the
//! saved file gives the buffer just after each intermediate header's
//! edit. Lines borrow from the original .un~ input - only the array
//! of pointer slots is allocated.

const std = @import("std");
const undofile = @import("undofile.zig");

pub const BufferState = struct {
    lines: []const []const u8,
};

pub const ReplayError = error{
    SeqNotFound,
    RangeOutOfBounds,
} || std.mem.Allocator.Error;

/// Walk the undo tree from newhead down to `target_seq` (exclusive),
/// applying each visited header's entries as `u_undoredo` would (delete
/// `oldsize` rows starting at `top`, insert `lines`). Returns the buffer
/// state immediately after `target_seq`'s edit, i.e. the buffer as the
/// user would have seen with `curhead == target_seq`.
///
/// `initial` must be the buffer at newhead's time - typically the file
/// content of the buffer that the .un~ was written for. For
/// `target_seq == fh.seq_last` no walk is performed and `initial` is
/// returned.
pub fn snapshotAt(
    alloc: std.mem.Allocator,
    initial: []const []const u8,
    fh: *const undofile.FileHeader,
    target_seq: u32,
) ReplayError!BufferState {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(alloc);
    try lines.appendSlice(alloc, initial);

    if (target_seq == fh.seq_last) {
        return .{ .lines = try lines.toOwnedSlice(alloc) };
    }

    const start = findHeader(fh.headers, fh.seq_last)
        orelse return error.SeqNotFound;

    var cur: *const undofile.Header = start;
    var depth: usize = 0;
    while (cur.seq != target_seq) : (depth += 1) {
        if (depth > fh.headers.len * 4) return error.SeqNotFound;
        if (cur.next_seq == 0) return error.SeqNotFound;

        for (cur.entries) |e| {
            try applyEntry(alloc, &lines, e);
        }

        cur = findHeader(fh.headers, cur.next_seq)
            orelse return error.SeqNotFound;
    }

    return .{ .lines = try lines.toOwnedSlice(alloc) };
}

pub fn deinit(state: BufferState, alloc: std.mem.Allocator) void {
    alloc.free(state.lines);
}

fn findHeader(headers: []const undofile.Header, seq: u32) ?*const undofile.Header {
    for (headers) |*h| {
        if (h.seq == seq) return h;
    }
    return null;
}

fn applyEntry(
    alloc: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    e: undofile.Entry,
) ReplayError!void {
    const top: usize = @intCast(e.top);
    if (top > lines.items.len) return error.RangeOutOfBounds;

    const oldsize: usize = if (e.bot == 0)
        lines.items.len - top
    else
        e.bot - top - 1;
    if (top + oldsize > lines.items.len) return error.RangeOutOfBounds;

    var new_items: std.ArrayList([]const u8) = .empty;
    defer new_items.deinit(alloc);
    for (e.lines) |line| try new_items.append(alloc, line.bytes);

    try lines.replaceRange(alloc, top, oldsize, new_items.items);
}

const testing = std.testing;

const single_bytes: []const u8 = @embedFile("testdata/sample.un~");
const single_text: []const u8 = @embedFile("testdata/sample.txt");
const multi_bytes: []const u8 = @embedFile("testdata/multitree.un~");
const multi_text: []const u8 = @embedFile("testdata/multitree.txt");

const allocator = testing.allocator;

fn splitLines(alloc: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        try out.append(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

fn readText(alloc: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    return splitLines(alloc, s);
}

test "snapshotAt newhead returns saved file content" {
    const fh = try undofile.Parser.parse(allocator, single_bytes);
    defer undofile.Parser.deinit(fh, allocator);

    const text = try readText(allocator, single_text);
    defer allocator.free(text);

    const got = try snapshotAt(allocator, text, &fh, fh.seq_last);
    defer deinit(got, allocator);

    try testing.expectEqual(text.len, got.lines.len);
    for (text, got.lines) |w, l| try testing.expectEqualStrings(w, l);
}

    test "multitree leaves reconstruct correctly" {
        const fh = try undofile.Parser.parse(allocator, multi_bytes);
        defer undofile.Parser.deinit(fh, allocator);

        const newhead_text = try readText(allocator, multi_text);
        defer allocator.free(newhead_text);

        // Snapshotting a seq that's on the redo chain reachable from the
        // curhead gives the buffer state immediately after that edit;
        // seqs on abandoned branches (H2, the path the user undid away
        // from) cannot be reconstructed without the in-memory entries
        // nvim discarded when the user took the undo branch.
        const reachable = [_]struct { seq: u32, want: []const u8 }{
            .{ .seq = 3, .want = "init\nappendA\nappendC" },
            .{ .seq = 1, .want = "init\nappendA" },
        };
        for (reachable) |c| {
            const got = try snapshotAt(allocator, newhead_text, &fh, c.seq);
            defer deinit(got, allocator);
            const want_lines = try splitLines(allocator, c.want);
            defer allocator.free(want_lines);
            try testing.expectEqual(want_lines.len, got.lines.len);
            for (want_lines, got.lines) |w, l| try testing.expectEqualStrings(w, l);
        }

        try testing.expectError(error.SeqNotFound, snapshotAt(allocator, newhead_text, &fh, 2));
    }

    test "diff between reachable multitree leaves" {
        const fh = try undofile.Parser.parse(allocator, multi_bytes);
        defer undofile.Parser.deinit(fh, allocator);
        const newhead_text = try readText(allocator, multi_text);
        defer allocator.free(newhead_text);

        const a = try snapshotAt(allocator, newhead_text, &fh, 1);
        defer deinit(a, allocator);
        const b = try snapshotAt(allocator, newhead_text, &fh, 3);
        defer deinit(b, allocator);

        try testing.expectEqual(@as(usize, 2), a.lines.len);
        try testing.expectEqual(@as(usize, 3), b.lines.len);
        try testing.expectEqualStrings("init", a.lines[0]);
        try testing.expectEqualStrings("appendA", a.lines[1]);
        try testing.expectEqualStrings("init", b.lines[0]);
        try testing.expectEqualStrings("appendA", b.lines[1]);
        try testing.expectEqualStrings("appendC", b.lines[2]);
    }