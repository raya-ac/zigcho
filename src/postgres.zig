const std = @import("std");

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
    const raw = c.PQexec(conn, sql.ptr) orelse return error.DatabaseQueryFailed;
    defer c.PQclear(raw);
    if (!statusOk(c.PQresultStatus(raw))) {
        reportError(conn, raw);
        return error.DatabaseQueryFailed;
    }
}

pub fn query(conn: *c.PGconn, sql: [:0]const u8) !Result {
    const raw = c.PQexec(conn, sql.ptr) orelse return error.DatabaseQueryFailed;
    errdefer c.PQclear(raw);
    if (!statusOk(c.PQresultStatus(raw))) {
        reportError(conn, raw);
        return error.DatabaseQueryFailed;
    }
    return .{ .raw = raw };
}

pub fn queryParams(allocator: std.mem.Allocator, conn: *c.PGconn, sql: [:0]const u8, params: []const ?[]const u8) !Result {
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
        return error.DatabaseQueryFailed;
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
            pool.mutex.lockUncancelable(pool.io);
            std.debug.assert(pool.in_use[self.index]);
            pool.in_use[self.index] = false;
            pool.available.signal(pool.io);
            pool.mutex.unlock(pool.io);
            self.* = undefined;
        }
    };

    pub fn acquire(self: *Pool) Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            for (self.in_use, 0..) |busy, index| {
                if (busy) continue;
                self.in_use[index] = true;
                const conn = self.connections[index];
                if (c.PQstatus(conn) != c.CONNECTION_OK) c.PQreset(conn);
                if (c.PQstatus(conn) != c.CONNECTION_OK) {
                    self.in_use[index] = false;
                    self.available.signal(self.io);
                    continue;
                }
                return .{ .pool = self, .index = index, .conn = conn };
            }
            self.available.waitUncancelable(self.io, &self.mutex);
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
