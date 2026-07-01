//! Replay Neovim's undo/redo entry chain into a concrete buffer state.
//!
//! Given a target sequence number, walk prev_seq links back to `oldhead_seq`
//! (collected in `fh.oldhead_seq`), then replay each header's entries in
//! chronological order onto an initially-empty line buffer.
//!
//! Result lines borrow from the original .un~ input — no copy of the line
//! text happens, only the array of pointer slots is allocated.

const std = @import("std");
const undofile = @import("undofile.zig");

pub const BufferState = struct {
    lines: []const []const u8,
};

pub const ReplayError = error{
    SeqNotFound,
    RangeOutOfBounds,
} || std.mem.Allocator.Error;

pub fn snapshotAt(
    alloc: std.mem.Allocator,
    fh: *const undofile.FileHeader,
    target_seq: u32,
) ReplayError!BufferState {
    var path: std.ArrayList(*const undofile.Header) = .empty;
    defer path.deinit(alloc);

    var cur_seq: u32 = target_seq;
    var depth: usize = 0;
    while (true) : (depth += 1) {
        const h = findHeader(fh.headers, cur_seq) orelse return error.SeqNotFound;
        try path.append(alloc, h);
        if (cur_seq == fh.oldhead_seq) break;
        if (h.prev_seq == 0) break;
        if (depth > fh.headers.len * 4) return error.SeqNotFound;
        cur_seq = h.prev_seq;
    }

    std.mem.reverse(*const undofile.Header, path.items);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(alloc);

    for (path.items) |h| {
        for (h.entries) |e| {
            try applyEntry(alloc, &lines, e);
        }
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

    const oldsize: usize = if (e.bot == 0) lines.items.len - top else e.bot - top - 1;
    if (top + oldsize > lines.items.len) return error.RangeOutOfBounds;

    var new_items: std.ArrayList([]const u8) = .empty;
    defer new_items.deinit(alloc);
    for (e.lines) |line| try new_items.append(alloc, line.bytes);

    try lines.replaceRange(top, oldsize, new_items.items);
}

const testing = std.testing;

const allocator = testing.allocator;

const fixture_path = "tests/fixtures/sample.un~";

test "snapshotAt returns the file's current buffer" {
    const input = try std.fs.cwd().readFileAlloc(allocator, fixture_path, 1 << 20);
    defer allocator.free(input);
    const fh = try undofile.Parser.parse(allocator, input);
    defer undofile.Parser.deinit(fh, allocator);

    const want = try std.fs.cwd().readFileAlloc(allocator, "tests/fixtures/sample.txt", 1 << 20);
    defer allocator.free(want);
    const want_lines = try splitLines(allocator, want);
    defer allocator.free(want_lines);

    const got = try snapshotAt(allocator, &fh, fh.seq_last);
    defer deinit(got, allocator);

    try testing.expectEqual(want_lines.len, got.lines.len);
    for (want_lines, got.lines) |w, l| {
        try testing.expectEqualStrings(w, l);
    }
}

test "snapshotAt walks alt_prev branch path" {
    const input = try std.fs.cwd().readFileAlloc(allocator, fixture_path, 1 << 20);
    defer allocator.free(input);
    const fh = try undofile.Parser.parse(allocator, input);
    defer undofile.Parser.deinit(fh, allocator);

    for (fh.headers) |h| {
        _ = try snapshotAt(allocator, &fh, h.seq);
    }
}

fn splitLines(alloc: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        try out.append(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}