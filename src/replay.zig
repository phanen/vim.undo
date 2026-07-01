//! Placeholder — replay logic will be implemented next.
const std = @import("std");
const undofile = @import("undofile.zig");

pub const BufferState = struct {
    lines: []const []const u8,
};

pub fn snapshotAt(
    alloc: std.mem.Allocator,
    fh: *const undofile.FileHeader,
    target_seq: u32,
) !BufferState {
    _ = alloc;
    _ = fh;
    _ = target_seq;
    return error.NotImplemented;
}