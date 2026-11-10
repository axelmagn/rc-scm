//! an exceedingly bare-bones scheme parser

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // for now, read stdin and emit tokens
    const stdin_file = std.Io.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.reader(init.io, &stdin_buf);

    var parser: Parser = try .init(&stdin_reader.interface, init.gpa);
    defer parser.deinit();

    // parse each value and print it on a new line
    while (try parser.read()) |value| {
        std.debug.print("{f}\n", .{value});
    }
}

pub const Token = union(enum) {
    lparen,
    rparen,
    identifier: []const u8,
    integer: i64,
    eof,

    pub fn format(self: Token, writer: *std.Io.Writer) !void {
        switch (self) {
            .lparen => try writer.writeAll("lparen"),
            .rparen => try writer.writeAll("rparen"),
            .identifier => try writer.print("(identifier {s})", .{self.identifier}),
            .integer => try writer.print("(integer {d})", .{self.integer}),
            .eof => try writer.writeAll("eof"),
        }
    }
};

pub const Value = union(enum) {
    nil,
    identifier: []const u8,
    integer: i64,
    pair: struct { car: *Value, cdr: *Value },

    const nil_value: Value = .nil;

    const Error = std.Io.Writer.Error;

    pub fn format(self: Value, writer: *std.Io.Writer) Error!void {
        switch (self) {
            .nil => try writer.writeAll("()"),
            .identifier => |s| try writer.writeAll(s),
            .integer => |n| try writer.print("{d}", .{n}),
            // .pair => |p| try writer.print("({f} . {f})", .{ p.car, p.cdr }),
            .pair => |p| {
                try writer.print("({f}", .{p.car});
                try p.cdr.formatCdr(writer);
            },
        }
    }

    pub fn formatCdr(self: Value, writer: *std.Io.Writer) Error!void {
        switch (self) {
            .nil => try writer.writeByte(')'),
            .pair => |p| {
                try writer.writeByte(' ');
                try p.car.format(writer);
                try p.cdr.formatCdr(writer);
            },
            else => {
                try writer.writeAll(" . ");
                try self.format(writer);
            },
        }
    }
};

pub const Scanner = struct {
    /// source character stream
    src: *std.Io.Reader,
    /// string pool, used to take ownership of strings from src
    string_pool: StringPool,
    /// currently buffered token
    token: ?Token = null,
    /// string buffer
    scan_buf: [256]u8 = undefined,
    /// error message
    err_buf: [256 + 64]u8 = undefined,
    err_msg: ?[]u8 = null,

    const ident_initial = letter.orOp(special_initial);
    const ident_subsequent = ident_initial.orOp(digit).orOp(special_subsequent);

    const letter = CharMask.fromFn(std.ascii.isAlphabetic);
    const digit = CharMask.fromFn(std.ascii.isDigit);
    const hex_digit = CharMask.fromFn(std.ascii.isHex);
    const whitespace = CharMask.fromStr(&std.ascii.whitespace);
    const delimiter = whitespace.orOp(CharMask.fromStr("()"));
    const special_initial = CharMask.fromStr("!$%&*/:<=>?@^_~");
    const special_subsequent = explicit_sign.orOp(CharMask.fromStr(".@"));
    const explicit_sign = CharMask.fromStr("+-");

    const Error = error{InvalidToken} ||
        std.Io.Reader.Error ||
        std.mem.Allocator.Error ||
        std.mem.PrintError;

    pub fn peek(self: *Scanner) Error!Token {
        if (self.token == null) {
            self.token = try self.scan();
        }
        return self.token.?;
    }

    pub fn next(self: *Scanner) Error!Token {
        defer self.token = null;
        return self.peek();
    }

    fn scan(self: *Scanner) Error!Token {
        try self.skipWhitespace();

        const c = self.src.takeByte() catch |err| {
            if (err == error.EndOfStream) return .eof;
            return err;
        };
        return switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            else => blk: {
                const text = try self.scanUntilDelimiter(c);
                break :blk try self.parseAtom(text);
            },
        };
    }

    fn skipWhitespace(self: *Scanner) Error!void {
        while (true) {
            const c = self.src.peekByte() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            if (!whitespace.check(c)) break;
            _ = try self.src.takeByte();
        }
    }

    fn scanUntilDelimiter(self: *Scanner, first_char: u8) Error![]const u8 {
        self.scan_buf[0] = first_char;
        var i: usize = 1;
        while (true) {
            const c = self.src.peekByte() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (delimiter.check(c)) break;
            self.scan_buf[i] = try self.src.takeByte();
            i += 1;
        }
        return self.scan_buf[0..i];
    }

    fn parseAtom(self: *Scanner, atom: []const u8) Error!Token {
        if (parseInteger(atom)) |tok| return tok;
        if (try self.parseIdentifier(atom)) |tok| return tok;
        self.err_msg = try std.mem.print(&self.err_buf, "Invalid token: {s}", .{atom});
        return error.InvalidToken;
    }

    fn parseIdentifier(self: *Scanner, atom: []const u8) Error!?Token {
        std.debug.assert(atom.len > 0);
        if (!ident_initial.check(atom[0])) return null;
        for (1..atom.len) |i| {
            if (!ident_subsequent.check(atom[i])) return null;
        }
        const owned = try self.string_pool.intern(atom);
        return .{ .identifier = owned };
    }

    fn parseInteger(atom: []const u8) ?Token {
        std.debug.assert(atom.len > 0);
        var sign: i64 = 1;
        var pos: usize = 0;
        if (atom[0] == '-') {
            sign = -1;
            pos += 1;
        } else if (atom[0] == '+') {
            pos += 1;
        }
        var num: i64 = 0;
        for (atom[pos..]) |c| {
            if (c < '0' or c > '9') return null;
            const d: u8 = c - '0';
            num *= 10;
            num += @intCast(d);
        }
        return .{ .integer = num };
    }
};

pub const Parser = struct {
    scanner: Scanner,
    values_pool: std.heap.MemoryPool(Value),
    values_alloc: std.mem.Allocator,

    pub const Error = error{ParseError} || Scanner.Error;

    const init_values_pool_capacity = 4096;

    pub fn init(src: *std.Io.Reader, gpa: std.mem.Allocator) Error!Parser {
        return .{
            .scanner = .{ .src = src, .string_pool = try .init(gpa) },
            .values_pool = try .initCapacity(gpa, init_values_pool_capacity),
            .values_alloc = gpa,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.scanner.string_pool.deinit();
        self.values_pool.deinit(self.values_alloc);
    }

    pub fn read(self: *Parser) Error!?Value {
        if (try self.scanner.peek() == .eof) return null;
        return try self.readDatum();
    }

    pub fn readDatum(self: *Parser) Error!Value {
        const tok = try self.scanner.next();
        return switch (tok) {
            .lparen => try self.readTail(),
            // repack atoms
            .identifier => |s| .{ .identifier = s },
            .integer => |n| .{ .integer = n },
            else => blk: {
                std.debug.print("err: {f}\n", .{tok});
                break :blk Error.ParseError;
            },
        };
    }

    pub fn readTail(self: *Parser) Error!Value {
        if (try self.scanner.peek() == .rparen) return .nil;
        // var head = try self.values_pool.create(self.values_alloc);
        var car = try self.values_pool.create(self.values_alloc);
        car.* = try self.readDatum();
        var cdr = try self.values_pool.create(self.values_alloc);
        cdr.* = .nil;
        const head: Value = .{ .pair = .{ .car = car, .cdr = cdr } };
        var curr_val = cdr;
        while (try self.scanner.peek() != .rparen) {
            if (try self.scanner.peek() == .eof) return Error.ParseError;

            car = try self.values_pool.create(self.values_alloc);
            car.* = try self.readDatum();

            cdr = try self.values_pool.create(self.values_alloc);
            cdr.* = .nil;

            curr_val.* = .{ .pair = .{ .car = car, .cdr = cdr } };

            curr_val = cdr;
        }
        // advance past rparen
        std.debug.assert(.rparen == try self.scanner.next());
        return head;
    }
};

/// interning pool for a set of strings
pub const StringPool = struct {
    index: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,

    const init_index_capacity = 1 << 12; // 4096
    const init_intern_capacity = 1 << 16; // ~65KB

    const Error = std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator) Error!StringPool {
        var interns: StringPool = .{ .index = .init(gpa), .arena = .init(gpa) };
        // warm up arena
        _ = try interns.arena.allocator().alloc(u8, init_intern_capacity);
        _ = interns.arena.reset(.retain_capacity);
        // alloc initial index capacity
        try interns.index.ensureTotalCapacity(init_index_capacity);
        return interns;
    }

    pub fn deinit(self: *StringPool) void {
        self.arena.deinit();
        self.index.deinit();
    }

    pub fn intern(self: *StringPool, str: []const u8) Error![]const u8 {
        if (self.index.getKey(str)) |existing| return existing;
        const owned = try self.arena.allocator().dupe(u8, str);
        try self.index.put(owned, {});
        return owned;
    }
};

pub const CharMask = struct {
    mask: u256,

    const one = @as(u256, 1);

    pub fn fromStr(str: []const u8) CharMask {
        var mask: u256 = 0;
        for (str) |c| {
            mask |= one << c;
        }
        return .{ .mask = mask };
    }

    pub fn fromFn(pred: fn (u8) bool) CharMask {
        var mask: u256 = 0;
        for (0..256) |i| {
            const c: u8 = @intCast(i);
            if (pred(c)) {
                mask |= one << c;
            }
        }
        return .{ .mask = mask };
    }

    pub fn orOp(lhs: CharMask, rhs: CharMask) CharMask {
        return .{ .mask = lhs.mask | rhs.mask };
    }

    pub fn andOp(lhs: CharMask, rhs: CharMask) CharMask {
        return .{ .mask = lhs.mask & rhs.mask };
    }

    pub inline fn check(self: CharMask, c: u8) bool {
        return self.mask & (one << c) > 0;
    }
};
