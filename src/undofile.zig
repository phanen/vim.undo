//! Neovim undo file (UF_VERSION 3) binary parser.
//! Schema: neovim/src/nvim/undo.c (serialize_uhp, unserialize_uhp,
//! serialize_uep, unserialize_uep).
//! All integers are big-endian on disk.

const std = @import("std");
const assert = std.debug.assert;

pub const marks_max: u32 = 26;

pub const magic_start: [9]u8 = "Vim\x9fUnDo\xe5".*;
pub const version: u16 = 3;

pub const MAGIC = struct {
    pub const header: u16 = 0x5fd0;
    pub const header_end: u16 = 0xe7aa;
    pub const entry: u16 = 0xf518;
    pub const entry_end: u16 = 0x3581;
};

pub const Pos = extern struct {
    lnum: i32,
    col: i32,
    coladd: i32,
};

pub const VisualInfo = extern struct {
    start: Pos,
    end: Pos,
    vi_mode: i32,
    vi_curswant: i32,
};

comptime {
    assert(magic_start.len == 9);
    assert(@sizeOf(Pos) == 12);
    assert(@sizeOf(VisualInfo) == 32);
}

pub const Line = struct {
    bytes: []const u8,
};

/// `top_line`..`bot_line` (exclusive) is the region the buffer occupied
/// before the change; `lines` is the post-change content of that region.
pub const Entry = struct {
    top_line: u32,
    bot_line: u32,
    lcount: u32,
    size: u32,
    lines: []Line,
};

pub const Header = struct {
    next_seq: u32,
    prev_seq: u32,
    alt_next_seq: u32,
    alt_prev_seq: u32,
    seq: u32,
    cursor: Pos,
    cursor_vcol: i32,
    flags: u16,
    namedm: [marks_max]Pos,
    visual: VisualInfo,
    time: u64,
    save_nr: u32,
    entries: []Entry,
    /// Opaque extmark bytes, kept raw until a dedicated parser is needed.
    extmarks_raw: []const u8,
};

pub const FileHeader = struct {
    line_count: u32,
    u_line_ptr: []const u8,
    u_line_lnum: u32,
    u_line_colnr: u32,
    oldhead_seq: u32,
    newhead_seq: u32,
    curhead_seq: u32,
    numhead: u32,
    seq_last: u32,
    seq_cur: u32,
    b_u_time_cur: u64,
    save_nr_last: u32,
    headers: []Header,
    /// Bytes between the last header's end-magic and EOF.
    /// Always starts with MAGIC.header_end on a well-formed file.
    trailer: []const u8,
};

pub const ParseError = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    InvalidMagic,
    InvalidFieldTag,
};

pub const ReadError = ParseError || std.mem.Allocator.Error;

pub const Parser = struct {
    input: []const u8,
    alloc: std.mem.Allocator,
    cursor_byte_offset: usize = 0,

    pub fn init(alloc: std.mem.Allocator, input: []const u8) Parser {
        return .{ .input = input, .alloc = alloc };
    }

    pub fn atEnd(self: *const Parser) bool {
        return self.cursor_byte_offset >= self.input.len;
    }

    fn remaining(self: *const Parser) usize {
        return self.input.len - self.cursor_byte_offset;
    }

    fn remainingSlice(self: *const Parser) []const u8 {
        return self.input[self.cursor_byte_offset..];
    }

    fn ensure(self: *const Parser, n: usize) ParseError!void {
        if (self.remaining() < n) return error.Truncated;
    }

    fn readByte(self: *Parser) ParseError!u8 {
        try self.ensure(1);
        const b = self.input[self.cursor_byte_offset];
        self.cursor_byte_offset += 1;
        return b;
    }

    fn readInt(self: *Parser, comptime T: type) ParseError!T {
        const n: usize = @divExact(@typeInfo(T).int.bits, 8);
        try self.ensure(n);
        const value = std.mem.readInt(T, self.input[self.cursor_byte_offset..][0..n], .big);
        self.cursor_byte_offset += n;
        return value;
    }

    fn peekInt(self: *Parser, comptime T: type) ParseError!T {
        const n: usize = @divExact(@typeInfo(T).int.bits, 8);
        try self.ensure(n);
        return std.mem.readInt(T, self.input[self.cursor_byte_offset..][0..n], .big);
    }

    fn readSlice(self: *Parser, n: usize) ParseError![]const u8 {
        try self.ensure(n);
        const s = self.input[self.cursor_byte_offset..][0..n];
        self.cursor_byte_offset += n;
        return s;
    }

    fn readLengthPrefixed(self: *Parser) ParseError![]const u8 {
        const len = try self.readInt(u32);
        if (len == 0xffff_ffff) return error.Truncated;
        return self.readSlice(len);
    }

    fn readMagic(self: *Parser, expected: []const u8) ParseError!void {
        try self.ensure(expected.len);
        if (!std.mem.eql(u8, self.input[self.cursor_byte_offset..][0..expected.len], expected)) {
            return error.BadMagic;
        }
        self.cursor_byte_offset += expected.len;
    }

    fn expectU16Magic(self: *Parser, expected: u16) ParseError!void {
        const actual = try self.readInt(u16);
        if (actual != expected) return error.InvalidMagic;
    }

    fn readPos(self: *Parser) ParseError!Pos {
        return .{
            .lnum = try self.readInt(i32),
            .col = try self.readInt(i32),
            .coladd = try self.readInt(i32),
        };
    }

    fn readVisualInfo(self: *Parser) ParseError!VisualInfo {
        return .{
            .start = try self.readPos(),
            .end = try self.readPos(),
            .vi_mode = try self.readInt(i32),
            .vi_curswant = try self.readInt(i32),
        };
    }

    fn readEntry(self: *Parser) ReadError!Entry {
        const top_line = try self.readInt(u32);
        const bot_line = try self.readInt(u32);
        const lcount = try self.readInt(u32);
        const size = try self.readInt(u32);

        const lines = try self.alloc.alloc(Line, size);
        errdefer self.alloc.free(lines);
        var i: usize = 0;
        while (i < size) : (i += 1) {
            lines[i] = .{ .bytes = try self.readLengthPrefixed() };
        }
        return .{
            .top_line = top_line,
            .bot_line = bot_line,
            .lcount = lcount,
            .size = size,
            .lines = lines,
        };
    }

    fn readEntries(self: *Parser) ReadError![]Entry {
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| self.alloc.free(e.lines);
            list.deinit(self.alloc);
        }
        while (true) {
            const peek = try self.peekInt(u16);
            if (peek != MAGIC.entry) break;
            _ = try self.readInt(u16);
            const entry = try self.readEntry();
            errdefer self.alloc.free(entry.lines);
            try list.append(self.alloc, entry);
        }
        return list.toOwnedSlice(self.alloc);
    }

    /// Reads optional `(len:u8, tag:u8, payload: len bytes)` records until a
    /// terminator byte (0). `len` is the payload length, NOT including the
    /// tag byte (see nvim's put_header_ptr format). The same tag (= 1) means
    /// `save_nr` on both the file header and per-header records.
    fn readSaveNrOptionalFields(self: *Parser, save_nr: *u32) ParseError!void {
        while (true) {
            const len = try self.readByte();
            if (len == 0) return;
            try self.ensure(len);
            const tag_byte = try self.readByte();
            const payload = try self.readSlice(len);
            switch (tag_byte) {
                1 => {
                    if (payload.len != 4) return error.Truncated;
                    save_nr.* = std.mem.readInt(u32, payload[0..4], .big);
                },
                else => return error.InvalidFieldTag,
            }
        }
    }

    fn readFileHeader(self: *Parser) ReadError!FileHeader {
        const line_count = try self.readInt(u32);
        const u_line_ptr_len = try self.readInt(u32);
        const u_line_ptr = try self.readSlice(u_line_ptr_len);
        const u_line_lnum = try self.readInt(u32);
        const u_line_colnr = try self.readInt(u32);
        const oldhead_seq = try self.readInt(u32);
        const newhead_seq = try self.readInt(u32);
        const curhead_seq = try self.readInt(u32);
        const numhead = try self.readInt(u32);
        const seq_last = try self.readInt(u32);
        const seq_cur = try self.readInt(u32);
        const b_u_time_cur = try self.readInt(u64);

        var save_nr_last: u32 = 0;
        try self.readSaveNrOptionalFields(&save_nr_last);

        var headers: std.ArrayList(Header) = .empty;
        errdefer {
            for (headers.items) |h| freeHeader(h, self.alloc);
            headers.deinit(self.alloc);
        }
        while (!self.atEnd()) {
            const peek = try self.peekInt(u16);
            if (peek != MAGIC.header) break;
            const header = try self.readHeader();
            errdefer freeHeader(header, self.alloc);
            try headers.append(self.alloc, header);
        }

        return .{
            .line_count = line_count,
            .u_line_ptr = u_line_ptr,
            .u_line_lnum = u_line_lnum,
            .u_line_colnr = u_line_colnr,
            .oldhead_seq = oldhead_seq,
            .newhead_seq = newhead_seq,
            .curhead_seq = curhead_seq,
            .numhead = numhead,
            .seq_last = seq_last,
            .seq_cur = seq_cur,
            .b_u_time_cur = b_u_time_cur,
            .save_nr_last = save_nr_last,
            .headers = try headers.toOwnedSlice(self.alloc),
            .trailer = self.remainingSlice(),
        };
    }

    fn readHeader(self: *Parser) ReadError!Header {
        try self.expectU16Magic(MAGIC.header);

        const next_seq = try self.readInt(u32);
        const prev_seq = try self.readInt(u32);
        const alt_next_seq = try self.readInt(u32);
        const alt_prev_seq = try self.readInt(u32);
        const seq = try self.readInt(u32);
        if (seq == 0) return error.Truncated;

        const cursor = try self.readPos();
        const cursor_vcol = try self.readInt(i32);
        const flags = try self.readInt(u16);

        var namedm: [marks_max]Pos = undefined;
        for (&namedm) |*p| p.* = try self.readPos();

        const visual = try self.readVisualInfo();
        const time = try self.readInt(u64);

        var save_nr: u32 = 0;
        try self.readSaveNrOptionalFields(&save_nr);

        const entries = try self.readEntries();
        try self.expectU16Magic(MAGIC.entry_end);

        // Extmarks follow: each prefixed with MAGIC.entry then a u32 type.
        // Schema is opaque here; skip until the section terminator
        // (MAGIC.entry_end again) which closes the per-header block.
        const extmarks_start = self.cursor_byte_offset;
        var extmarks_end: ?usize = null;
        while (self.remaining() >= 2) {
            const peek = try self.peekInt(u16);
            if (peek == MAGIC.entry_end) {
                extmarks_end = self.cursor_byte_offset;
                _ = try self.readInt(u16);
                break;
            }
            self.cursor_byte_offset += 1;
        }
        const terminator_pos = extmarks_end orelse return error.Truncated;

        return .{
            .next_seq = next_seq,
            .prev_seq = prev_seq,
            .alt_next_seq = alt_next_seq,
            .alt_prev_seq = alt_prev_seq,
            .seq = seq,
            .cursor = cursor,
            .cursor_vcol = cursor_vcol,
            .flags = flags,
            .namedm = namedm,
            .visual = visual,
            .time = time,
            .save_nr = save_nr,
            .entries = entries,
            .extmarks_raw = self.input[extmarks_start..terminator_pos],
        };
    }

    pub fn parse(alloc: std.mem.Allocator, input: []const u8) ReadError!FileHeader {
        var p: Parser = .init(alloc, input);

        try p.readMagic(&magic_start);
        const v = try p.readInt(u16);
        if (v != version) return error.UnsupportedVersion;
        _ = try p.readSlice(32); // sha256 hash, currently unused

        return p.readFileHeader();
    }

    pub fn deinit(fh: FileHeader, alloc: std.mem.Allocator) void {
        for (fh.headers) |h| freeHeader(h, alloc);
        alloc.free(fh.headers);
    }

    fn freeHeader(h: Header, alloc: std.mem.Allocator) void {
        for (h.entries) |e| alloc.free(e.lines);
        alloc.free(h.entries);
    }
};

const testing = std.testing;

test "magic and version constants" {
    try testing.expectEqualSlices(u8, &magic_start, "Vim\x9fUnDo\xe5");
    try testing.expectEqual(@as(u16, 3), version);
    try testing.expectEqual(@as(u16, 0x5fd0), MAGIC.header);
    try testing.expectEqual(@as(u16, 0xe7aa), MAGIC.header_end);
    try testing.expectEqual(@as(u16, 0xf518), MAGIC.entry);
    try testing.expectEqual(@as(u16, 0x3581), MAGIC.entry_end);
}

const fixture_bytes: []const u8 = @embedFile("testdata/sample.un~");

test "parse fixture roundtrip" {
    const fh = try Parser.parse(testing.allocator, fixture_bytes);
    defer Parser.deinit(fh, testing.allocator);

    try testing.expect(fh.headers.len > 0);
    try testing.expect(fh.numhead >= 1);

    var total_entries: usize = 0;
    for (fh.headers) |h| {
        try testing.expect(h.seq > 0);
        try testing.expect(h.namedm.len == marks_max);
        total_entries += h.entries.len;
        for (h.entries) |e| {
            try testing.expectEqual(e.size, @as(u32, @intCast(e.lines.len)));
        }
    }
    try testing.expect(total_entries > 0);

    if (fh.trailer.len >= 2) {
        const m = std.mem.readInt(u16, fh.trailer[0..2], .big);
        try testing.expectEqual(MAGIC.header_end, m);
    }
}
