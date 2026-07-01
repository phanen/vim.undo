//! Neovim undo file (UF_VERSION 3) binary parser.
//!
//! Schema reference: neovim/src/nvim/undo.c (serialize_uhp, unserialize_uhp,
//! serialize_uep, unserialize_uep).
//!
//! All integers are little-endian (see `undo_read_4c` / `get4c` in nvim).
//! `time_t` is read as 8 bytes little-endian via `get8ctime`.

const std = @import("std");

pub const NMARKS: usize = 26; // 'z' - 'a' + 1

pub const magic_start: [9]u8 = "Vim\x9fUnDo\xe5".*;
pub const version: u16 = 3;

/// Optional-field tags. Both `save_nr_last` (file header) and `uh_save_nr`
/// (per-header) use the numeric tag value 1 in the on-disk format; we keep
/// them as separate `u8` constants and let callers dispatch by their
/// enclosing context.
pub const OptTag = struct {
    pub const save_nr_last: u8 = 1; // UF_LAST_SAVE_NR, on the file header
    pub const uh_save_nr: u8 = 1; // UHP_SAVE_NR, on each u_header
};

/// Magic terminator / separator values.
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

/// Length-prefixed string entry as stored in the file.
/// `bytes` references into the input buffer (zero-copy).
pub const Line = struct {
    bytes: []const u8,
};

/// One `u_entry` as written by `serialize_uep` / `unserialize_uep`.
///
/// `top` / `bot` / `lcount` are 1-indexed line numbers; `top..bot` (exclusive)
/// is the region the original buffer occupied when the change was saved.
/// `size` is the number of lines stored in `lines` (the "new" content).
pub const Entry = struct {
    top: u32,
    bot: u32,
    lcount: u32,
    size: u32,
    lines: []Line,
};

/// One `u_header` as written by `serialize_uhp`.
///
/// Pointer fields use sequence numbers in the file (see `put_header_ptr`).
/// Extmarks are read as a raw byte slice for now — the format is opaque and
/// can be parsed separately if needed.
pub const Header = struct {
    next_seq: u32,
    prev_seq: u32,
    alt_next_seq: u32,
    alt_prev_seq: u32,
    seq: u32,
    cursor: Pos,
    cursor_vcol: i32,
    flags: u16,
    namedm: [NMARKS]Pos,
    visual: VisualInfo,
    time: u64,
    save_nr: u32,
    entries: []Entry,
    extmarks_raw: []const u8,
};

/// Top-level undo file structure (everything after the magic + version + hash).
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
    /// Raw trailer between the last header end-magic and end-of-file.
    /// Should start with MAGIC.header_end (= 0xe7aa).
    trailer: []const u8,
};

pub const ParseError = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    InvalidHeaderMagic,
    InvalidHeaderEndMagic,
    InvalidEntryMagic,
    InvalidEntryEndMagic,
    InvalidFieldTag,
};

pub const ReadError = ParseError || std.mem.Allocator.Error;

/// Parser owns the input bytes; everything it returns borrows from `input`.
pub const Parser = struct {
    input: []const u8,
    alloc: std.mem.Allocator,
    pos: usize = 0,

    pub fn init(alloc: std.mem.Allocator, input: []const u8) Parser {
        return .{ .input = input, .alloc = alloc };
    }

    pub fn atEnd(self: *const Parser) bool {
        return self.pos >= self.input.len;
    }

    pub fn remaining(self: *const Parser) usize {
        return self.input.len - self.pos;
    }

    fn remainingSlice(self: *const Parser) []const u8 {
        return self.input[self.pos..];
    }

    pub fn ensure(self: *const Parser, n: usize) ParseError!void {
        if (self.remaining() < n) return error.Truncated;
    }

    pub fn readByte(self: *Parser) ParseError!u8 {
        try self.ensure(1);
        const b = self.input[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readInt(self: *Parser, comptime T: type) ParseError!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        try self.ensure(n);
        const slice = self.input[self.pos..][0..n];
        const value = std.mem.readInt(T, slice, .big);
        self.pos += n;
        return value;
    }

    pub fn readArray(self: *Parser, comptime n: usize) ParseError!*[n]u8 {
        try self.ensure(n);
        const ptr: *[n]u8 = self.input[self.pos..][0..n];
        self.pos += n;
        self.pos += n;
        return ptr;
    }

    pub fn readSlice(self: *Parser, n: usize) ParseError![]const u8 {
        try self.ensure(n);
        const s = self.input[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    /// Reads `n` bytes into a runtime-sized slice. Prefer this over `readArray`
    /// when `n` is not comptime-known.
    pub fn readBytes(self: *Parser, n: usize) ParseError![]const u8 {
        return self.readSlice(n);
    }

    /// Reads a u32 length-prefix followed by that many bytes. Returns the slice.
    pub fn readLengthPrefixed(self: *Parser) ParseError![]const u8 {
        const len = try self.readInt(u32);
        // u32 max-length sanity (undofile uses i32 internally for line length).
        if (len == 0xffff_ffff) return error.Truncated;
        return self.readSlice(len);
    }

    pub fn readMagic(self: *Parser, expected: []const u8) ParseError!void {
        try self.ensure(expected.len);
        if (!std.mem.eql(u8, self.input[self.pos..][0..expected.len], expected)) {
            return error.BadMagic;
        }
        self.pos += expected.len;
    }

    pub fn readU16Magic(self: *Parser, expected: u16) ParseError!void {
        const actual = try self.readInt(u16);
        if (actual != expected) return error.InvalidHeaderMagic;
    }

    /// Reads a series of optional `(len:u8, tag:u8, value...)` fields until a
    /// terminator byte (0) is seen. Returns the byte right after the
    /// terminator position.
    fn readOptionalFields(self: *Parser) ParseError!void {
        while (true) {
            const len = try self.readByte();
            if (len == 0) return;
            try self.ensure(len);
            const tag = try self.readByte();
            _ = tag;
            // Skip the payload bytes; known tags are validated by callers
            // before calling this (via `readHeader` / `readFileHeader`).
            try self.readSlice(len - 1);
        }
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

    /// Reads a single u_entry. Caller has already consumed the UF_ENTRY_MAGIC.
    fn readEntry(self: *Parser) ReadError!Entry {
        const top = try self.readInt(u32);
        const bot = try self.readInt(u32);
        const lcount = try self.readInt(u32);
        const size = try self.readInt(u32);

        const lines = try self.alloc.alloc(Line, size);
        for (0..size) |i| {
            const bytes = try self.readLengthPrefixed();
            lines[i] = .{ .bytes = bytes };
        }
        return .{
            .top = top,
            .bot = bot,
            .lcount = lcount,
            .size = size,
            .lines = lines,
        };
    }

    /// Reads all u_entries that follow the UF_HEADER_MAGIC for a single header.
    /// Stops at the first non-UF_ENTRY_MAGIC marker (which should be either
    /// UF_ENTRY_END_MAGIC after the entries, or 0x3581 after the extmarks).
    fn readEntries(self: *Parser, alloc: std.mem.Allocator) ReadError![]Entry {
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| alloc.free(e.lines);
            list.deinit(alloc);
        }
        while (true) {
            const peek = try self.peekInt(u16);
            if (peek != MAGIC.entry) break;
            _ = try self.readInt(u16); // consume UF_ENTRY_MAGIC
            const e = try self.readEntry();
            try list.append(alloc, e);
        }
        return list.toOwnedSlice(alloc);
    }

    pub fn peekInt(self: *Parser, comptime T: type) ParseError!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        try self.ensure(n);
        return std.mem.readInt(T, self.input[self.pos..][0..n], .big);
    }

    /// Read the file header. Caller has consumed magic + version + 32-byte hash.
    fn readFileHeader(self: *Parser, alloc: std.mem.Allocator) ReadError!FileHeader {
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
        // Optional fields block on the file header.
        while (true) {
            const len = try self.readByte();
            if (len == 0) break;
            try self.ensure(len);
            const tag_byte = try self.readByte();
            const payload = try self.readSlice(len);
            switch (tag_byte) {
                OptTag.save_nr_last => {
                    if (payload.len != 4) return error.Truncated;
                    save_nr_last = std.mem.readInt(u32, payload[0..4], .big);
                },
                else => return error.InvalidFieldTag,
            }
        }

        // Headers follow.
        var headers: std.ArrayList(Header) = .empty;
        errdefer {
            for (headers.items) |*h| self.freeHeader(h);
            headers.deinit(self.alloc);
        }
        while (!self.atEnd()) {
            const peek = try self.peekInt(u16);
            if (peek != MAGIC.header) break;
            const h = try self.readHeader(alloc);
            try headers.append(alloc, h);
        }

        // Whatever's left is the trailer (should start with MAGIC.header_end).
        const trailer = self.remainingSlice();

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
            .headers = try headers.toOwnedSlice(alloc),
            .trailer = trailer,
        };
    }

    fn readHeader(self: *Parser, alloc: std.mem.Allocator) ReadError!Header {
        try self.readU16Magic(MAGIC.header);

        const next_seq = try self.readInt(u32);
        const prev_seq = try self.readInt(u32);
        const alt_next_seq = try self.readInt(u32);
        const alt_prev_seq = try self.readInt(u32);
        const seq = try self.readInt(u32);

        if (seq == 0) return error.Truncated;

        const cursor = try self.readPos();
        const cursor_vcol = try self.readInt(i32);
        const flags = try self.readInt(u16);

        var namedm: [NMARKS]Pos = undefined;
        for (&namedm) |*p| p.* = try self.readPos();

        const visual = try self.readVisualInfo();
        const time = try self.readInt(u64);

        var save_nr: u32 = 0;
        while (true) {
            const len = try self.readByte();
            if (len == 0) break;
            try self.ensure(len);
            const tag_byte = try self.readByte();
            const payload = try self.readSlice(len);
            switch (tag_byte) {
                OptTag.uh_save_nr => {
                    if (payload.len != 4) return error.Truncated;
                    save_nr = std.mem.readInt(u32, payload[0..4], .little);
                },
                else => return error.InvalidFieldTag,
            }
        }

        // Entries.
        const entries = try self.readEntries(alloc);

        // Entry-list terminator (UF_ENTRY_END_MAGIC = 0x3581).
        try self.readU16Magic(MAGIC.entry_end);

        // Extmarks: each starts with UF_ENTRY_MAGIC (0xf518) followed by a
        // u32 type then type-specific bytes. We don't have a schema here,
        // so we skip the whole extmark section by reading bytes until the
        // file-level terminator (UF_ENTRY_END_MAGIC = 0x3581) which also
        // closes the per-header block.
        const extmarks_start = self.pos;
        var extmarks_terminator_pos: usize = 0;
        while (true) {
            const peek = try self.peekInt(u16);
            if (peek == MAGIC.entry_end) {
                extmarks_terminator_pos = self.pos;
                _ = try self.readInt(u16);
                break;
            }
            if (self.remaining() < 2) return error.Truncated;
            self.pos += 1;
        }
        const extmarks_raw = self.input[extmarks_start..extmarks_terminator_pos];

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
            .extmarks_raw = extmarks_raw,
        };
    }

    fn freeHeader(p: *Parser, h: *Header) void {
        const alloc = p.alloc;
        for (h.entries) |e| alloc.free(e.lines);
        alloc.free(h.entries);
    }

    pub fn parse(alloc: std.mem.Allocator, input: []const u8) ReadError!FileHeader {
        var p: Parser = .init(alloc, input);

        try p.readMagic(&magic_start);
        const v = try p.readInt(u16);
        if (v != version) return error.UnsupportedVersion;
        _ = try p.readSlice(32); // sha256 hash, currently unused

        return p.readFileHeader(alloc);
    }

    pub fn deinit(fh: FileHeader, alloc: std.mem.Allocator) void {
        for (fh.headers) |*h| {
            for (h.entries) |e| alloc.free(e.lines);
            alloc.free(h.entries);
        }
        alloc.free(fh.headers);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
    const input = fixture_bytes;
    const fh = try Parser.parse(testing.allocator, input);
    defer Parser.deinit(fh, testing.allocator);

    try testing.expect(fh.headers.len > 0);
    try testing.expectEqual(@as(u16, 3), version);
    try testing.expect(fh.numhead >= 1);

    // The fixture was made by appending/deleting/inserting in a 3-line file.
    // We expect at least one header with at least one entry.
    var total_entries: usize = 0;
    for (fh.headers) |h| {
        try testing.expect(h.seq > 0);
        try testing.expect(h.namedm.len == NMARKS);
        total_entries += h.entries.len;
        for (h.entries) |e| {
            try testing.expectEqual(e.size, @as(u32, @intCast(e.lines.len)));
        }
    }
    try testing.expect(total_entries > 0);

    // Trailer should start with the header-end magic.
    if (fh.trailer.len >= 2) {
        const m = std.mem.readInt(u16, fh.trailer[0..2], .big);
        try testing.expectEqual(MAGIC.header_end, m);
    }
}
