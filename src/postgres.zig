const std = @import("std");
const telemetry = @import("telemetry.zig");

pub const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const Result = struct {
    raw: *c.PGresult,

    pub fn deinit(self: *Result) void {
        c.PQclear(self.raw);
        self.* = undefined;
    }

    pub fn rows(self: Result) usize {
        return @intCast(c.PQntuples(self.raw));
    }

    pub fn columns(self: Result) usize {
        return @intCast(c.PQnfields(self.raw));
    }

    pub fn isNull(self: Result, row: usize, column: usize) bool {
        return c.PQgetisnull(self.raw, @intCast(row), @intCast(column)) != 0;
    }

    pub fn value(self: Result, row: usize, column: usize) []const u8 {
        const ptr = c.PQgetvalue(self.raw, @intCast(row), @intCast(column));
        const len: usize = @intCast(c.PQgetlength(self.raw, @intCast(row), @intCast(column)));
        return ptr[0..len];
    }

    pub fn int(self: Result, comptime T: type, row: usize, column: usize) !T {
        if (self.isNull(row, column)) return error.DatabaseNull;
        return std.fmt.parseInt(T, self.value(row, column), 10);
    }

    pub fn float(self: Result, comptime T: type, row: usize, column: usize) !T {
        if (self.isNull(row, column)) return error.DatabaseNull;
        return std.fmt.parseFloat(T, self.value(row, column));
    }

    pub fn boolean(self: Result, row: usize, column: usize) !bool {
        if (self.isNull(row, column)) return error.DatabaseNull;
        const bytes = self.value(row, column);
        if (std.mem.eql(u8, bytes, "t")) return true;
        if (std.mem.eql(u8, bytes, "f")) return false;
        return error.InvalidDatabaseBoolean;
    }
};

fn statusOk(status: c.ExecStatusType) bool {
    return status == c.PGRES_COMMAND_OK or status == c.PGRES_TUPLES_OK;
}

fn reportError(conn: *c.PGconn, result: ?*c.PGresult) void {
    if (result) |raw| {
        const message = std.mem.trim(u8, std.mem.span(c.PQresultErrorMessage(raw)), " \t\r\n");
        if (message.len != 0) {
            std.log.err("postgres query failed: {s}", .{message});
            return;
        }
    }
    const message = std.mem.trim(u8, std.mem.span(c.PQerrorMessage(conn)), " \t\r\n");
    std.log.err("postgres connection failed: {s}", .{message});
}

fn resultError(raw: *c.PGresult) error{ UniqueViolation, DatabaseQueryFailed } {
    const state_ptr = c.PQresultErrorField(raw, c.PG_DIAG_SQLSTATE);
    if (state_ptr) |state| {
        if (std.mem.eql(u8, std.mem.span(state), "23505")) return error.UniqueViolation;
    }
    return error.DatabaseQueryFailed;
}

pub fn connect(conninfo: [:0]const u8) !*c.PGconn {
    const conn = c.PQconnectdb(conninfo.ptr) orelse return error.DatabaseOpenFailed;
    errdefer c.PQfinish(conn);
    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        reportError(conn, null);
        return error.DatabaseOpenFailed;
    }
    return conn;
}

pub fn exec(conn: *c.PGconn, sql: [:0]const u8) !void {
    const timer = telemetry.Timer.start(.postgres_query);
    defer timer.finish();
    const raw = c.PQexec(conn, sql.ptr) orelse return error.DatabaseQueryFailed;
    defer c.PQclear(raw);
    if (!statusOk(c.PQresultStatus(raw))) {
        reportError(conn, raw);
        return resultError(raw);
    }
}

pub fn query(conn: *c.PGconn, sql: [:0]const u8) !Result {
    const timer = telemetry.Timer.start(.postgres_query);
    defer timer.finish();
    const raw = c.PQexec(conn, sql.ptr) orelse return error.DatabaseQueryFailed;
    errdefer c.PQclear(raw);
    if (!statusOk(c.PQresultStatus(raw))) {
        reportError(conn, raw);
        return resultError(raw);
    }
    return .{ .raw = raw };
}

pub fn encodeBytea(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '\\';
    out[1] = 'x';
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[2 + index * 2] = alphabet[byte >> 4];
        out[3 + index * 2] = alphabet[byte & 0x0f];
    }
    return out;
}

fn hexNibble(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.InvalidDatabaseBytea,
    };
}

pub fn decodeBytea(allocator: std.mem.Allocator, text_value: []const u8) ![]u8 {
    if (text_value.len < 2 or text_value[0] != '\\' or text_value[1] != 'x' or (text_value.len - 2) % 2 != 0) return error.InvalidDatabaseBytea;
    const out = try allocator.alloc(u8, (text_value.len - 2) / 2);
    errdefer allocator.free(out);
    for (out, 0..) |*byte, index| byte.* = (try hexNibble(text_value[2 + index * 2])) << 4 | try hexNibble(text_value[3 + index * 2]);
    return out;
}

pub fn queryParams(allocator: std.mem.Allocator, conn: *c.PGconn, sql: [:0]const u8, params: []const ?[]const u8) !Result {
    const timer = telemetry.Timer.start(.postgres_query);
    defer timer.finish();
    const values = try allocator.alloc(?[*:0]const u8, params.len);
    defer allocator.free(values);
    const owned = try allocator.alloc(?[:0]u8, params.len);
    defer allocator.free(owned);
    @memset(owned, null);
    defer for (owned) |item| if (item) |value| allocator.free(value);

    for (params, 0..) |param, index| {
        if (param) |value| {
            const copy = try allocator.dupeZ(u8, value);
            owned[index] = copy;
            values[index] = copy.ptr;
        } else values[index] = null;
    }

    const raw = c.PQexecParams(
        conn,
        sql.ptr,
        @intCast(params.len),
        null,
        @ptrCast(values.ptr),
        null,
        null,
        0,
    ) orelse return error.DatabaseQueryFailed;
    errdefer c.PQclear(raw);
    if (!statusOk(c.PQresultStatus(raw))) {
        reportError(conn, raw);
        return resultError(raw);
    }
    return .{ .raw = raw };
}

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    conninfo: [:0]u8,
    connections: []*c.PGconn,
    in_use: []bool,
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,

    pub const default_size = 8;

    fn restoreConnection(self: *Pool, conn: *c.PGconn) bool {
        _ = self;
        if (c.PQstatus(conn) != c.CONNECTION_OK) c.PQreset(conn);
        if (c.PQstatus(conn) != c.CONNECTION_OK) return false;

        const transaction_status = c.PQtransactionStatus(conn);
        if (transaction_status == c.PQTRANS_IDLE) return true;
        if (transaction_status == c.PQTRANS_INTRANS or transaction_status == c.PQTRANS_INERROR) {
            exec(conn, "ROLLBACK") catch {
                c.PQreset(conn);
                return c.PQstatus(conn) == c.CONNECTION_OK and c.PQtransactionStatus(conn) == c.PQTRANS_IDLE;
            };
            std.log.warn("postgres pool rolled back a transaction left open by its previous lease", .{});
            return c.PQtransactionStatus(conn) == c.PQTRANS_IDLE;
        }

        // Synchronous callers should never return a connection while libpq is
        // active or unable to describe its state. Reset it before reuse rather
        // than allowing one request to inherit another request's connection.
        c.PQreset(conn);
        return c.PQstatus(conn) == c.CONNECTION_OK and c.PQtransactionStatus(conn) == c.PQTRANS_IDLE;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, conninfo: []const u8, size: usize) !Pool {
        if (size == 0 or size > 64) return error.InvalidPoolSize;
        const owned_conninfo = try allocator.dupeZ(u8, conninfo);
        errdefer allocator.free(owned_conninfo);
        const connections = try allocator.alloc(*c.PGconn, size);
        errdefer allocator.free(connections);
        const in_use = try allocator.alloc(bool, size);
        errdefer allocator.free(in_use);
        @memset(in_use, false);

        var opened: usize = 0;
        errdefer for (connections[0..opened]) |conn| c.PQfinish(conn);
        while (opened < size) : (opened += 1) connections[opened] = try connect(owned_conninfo);

        return .{
            .allocator = allocator,
            .io = io,
            .conninfo = owned_conninfo,
            .connections = connections,
            .in_use = in_use,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.in_use) |busy| std.debug.assert(!busy);
        for (self.connections) |conn| c.PQfinish(conn);
        self.allocator.free(self.connections);
        self.allocator.free(self.in_use);
        self.allocator.free(self.conninfo);
        self.* = undefined;
    }

    pub const Lease = struct {
        pool: *Pool,
        index: usize,
        conn: *c.PGconn,

        pub fn release(self: *Lease) void {
            const pool = self.pool;
            if (!pool.restoreConnection(self.conn)) std.log.err("postgres pool could not restore a released connection", .{});
            pool.mutex.lockUncancelable(pool.io);
            std.debug.assert(pool.in_use[self.index]);
            pool.in_use[self.index] = false;
            pool.available.signal(pool.io);
            pool.mutex.unlock(pool.io);
            self.* = undefined;
        }
    };

    pub fn acquire(self: *Pool) Lease {
        const acquire_timer = telemetry.Timer.start(.postgres_pool_acquire);
        defer acquire_timer.finish();
        const pending = telemetry.work.enter(.postgres_pool);
        defer pending.leave();
        var wait_ns: u64 = 0;
        defer telemetry.observe(.postgres_pool_wait, wait_ns);
        while (true) {
            const waiting_since = telemetry.clock.now();
            self.mutex.lockUncancelable(self.io);
            var selected: ?usize = null;
            for (self.in_use, 0..) |busy, index| {
                if (busy) continue;
                self.in_use[index] = true;
                selected = index;
                break;
            }
            if (selected == null) {
                self.available.waitUncancelable(self.io, &self.mutex);
                self.mutex.unlock(self.io);
                wait_ns +|= telemetry.clock.elapsed(waiting_since) orelse 0;
                continue;
            }
            const index = selected.?;
            const conn = self.connections[index];
            self.mutex.unlock(self.io);

            wait_ns +|= telemetry.clock.elapsed(waiting_since) orelse 0;

            // Reconnection may block on the network, so never hold the pool's
            // availability lock while libpq resets one leased connection.
            if (self.restoreConnection(conn)) return .{ .pool = self, .index = index, .conn = conn };

            self.mutex.lockUncancelable(self.io);
            self.in_use[index] = false;
            self.available.signal(self.io);
            self.mutex.unlock(self.io);
            std.log.err("postgres pool could not restore a connection", .{});
        }
    }
};

test "postgres pool rejects unsafe sizes before connecting" {
    try std.testing.expectError(error.InvalidPoolSize, Pool.init(std.testing.allocator, std.testing.io, "", 0));
    try std.testing.expectError(error.InvalidPoolSize, Pool.init(std.testing.allocator, std.testing.io, "", 65));
}

test "postgres pool bounds concurrent leases and returns them" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_URL") orelse return error.SkipZigTest;
    const conninfo = std.mem.span(raw_conninfo);
    var pool = try Pool.init(std.testing.allocator, std.testing.io, conninfo, 2);
    defer pool.deinit();

    var first = pool.acquire();
    var second = pool.acquire();
    var started: std.atomic.Value(bool) = .init(false);
    var failed: std.atomic.Value(bool) = .init(false);
    const Context = struct {
        pool: *Pool,
        started: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            var lease = context.pool.acquire();
            defer lease.release();
            exec(lease.conn, "SELECT 1") catch context.failed.store(true, .release);
        }
    };
    var context: Context = .{ .pool = &pool, .started = &started, .failed = &failed };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    while (!started.load(.acquire)) std.atomic.spinLoopHint();
    first.release();
    thread.join();
    second.release();
    try std.testing.expect(!failed.load(.acquire));
}

test "postgres pool never carries a transaction into the next lease" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_URL") orelse return error.SkipZigTest;
    const conninfo = std.mem.span(raw_conninfo);
    var pool = try Pool.init(std.testing.allocator, std.testing.io, conninfo, 1);
    defer pool.deinit();

    var dirty = pool.acquire();
    try exec(dirty.conn, "BEGIN");
    try exec(dirty.conn, "SET LOCAL application_name='zigcho_dirty_lease'");
    try std.testing.expect(c.PQtransactionStatus(dirty.conn) == c.PQTRANS_INTRANS);
    dirty.release();

    var clean = pool.acquire();
    defer clean.release();
    try std.testing.expect(c.PQtransactionStatus(clean.conn) == c.PQTRANS_IDLE);
    var application_name = try query(clean.conn, "SHOW application_name");
    defer application_name.deinit();
    try std.testing.expect(!std.mem.eql(u8, application_name.value(0, 0), "zigcho_dirty_lease"));
}
