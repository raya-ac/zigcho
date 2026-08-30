const d = @import("../deps.zig");
const std = d.std;
const builtin = d.builtin;
const http_boundary = d.http_boundary;
const App = @import("../app.zig").App;

const httpRequestDeadlineSeconds = http_boundary.requestDeadlineSeconds;

const PosixAddress = extern union {
    any: std.posix.sockaddr,
    in: std.posix.sockaddr.in,
    in6: std.posix.sockaddr.in6,
};

pub fn peerIp(stream: std.Io.net.Stream, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    var address: PosixAddress = undefined;
    var address_len: std.posix.socklen_t = @sizeOf(PosixAddress);
    std.posix.getpeername(stream.socket.handle, &address.any, &address_len) catch return null;
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const bytes: [4]u8 = @bitCast(address.in.addr);
            break :blk std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch null;
        },
        std.posix.AF.INET6 => blk: {
            const bytes = address.in6.addr;
            if (std.mem.eql(u8, bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                break :blk std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ bytes[12], bytes[13], bytes[14], bytes[15] }) catch null;
            }
            break :blk std.fmt.bufPrint(buffer, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                std.mem.readInt(u16, bytes[0..2], .big),
                std.mem.readInt(u16, bytes[2..4], .big),
                std.mem.readInt(u16, bytes[4..6], .big),
                std.mem.readInt(u16, bytes[6..8], .big),
                std.mem.readInt(u16, bytes[8..10], .big),
                std.mem.readInt(u16, bytes[10..12], .big),
                std.mem.readInt(u16, bytes[12..14], .big),
                std.mem.readInt(u16, bytes[14..16], .big),
            }) catch null;
        },
        else => null,
    };
}

pub fn httpDeadlineWatchdog(app: *App, stream: std.Io.net.Stream, io: std.Io, completed: *std.atomic.Value(bool), timeout_seconds: u16) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(timeout_seconds), .awake);
    if (completed.swap(true, .acq_rel)) return;
    app.http_gate.recordTimeout();
    stream.shutdown(io, .both) catch {};
}

pub fn serveConnection(app: *App, stream_value: std.Io.net.Stream, io: std.Io) void {
    defer app.http_gate.release();
    var stream = stream_value;
    defer stream.close(io);
    var peer_buffer: [64]u8 = undefined;
    const peer_ip = peerIp(stream, &peer_buffer);
    var recv: [64 * 1024]u8 = undefined;
    var send: [64 * 1024]u8 = undefined;
    var cr = stream.reader(io, &recv);
    var cw = stream.writer(io, &send);
    var server: std.http.Server = .init(&cr.interface, &cw.interface);
    var header_completed: std.atomic.Value(bool) = .init(false);
    var header_deadline: std.Io.Group = .init;
    header_deadline.concurrent(io, httpDeadlineWatchdog, .{ app, stream, io, &header_completed, app.http_header_timeout_seconds }) catch {
        _ = app.http_gate.rejected.fetchAdd(1, .acq_rel);
        return;
    };
    var req = server.receiveHead() catch {
        header_completed.store(true, .release);
        header_deadline.cancel(io);
        return;
    };
    header_completed.store(true, .release);
    header_deadline.cancel(io);

    if (httpRequestDeadlineSeconds(req.head.method, req.head.target, app.http_request_timeout_seconds, app.http_long_request_timeout_seconds)) |timeout_seconds| {
        var request_completed: std.atomic.Value(bool) = .init(false);
        var request_deadline: std.Io.Group = .init;
        request_deadline.concurrent(io, httpDeadlineWatchdog, .{ app, stream, io, &request_completed, timeout_seconds }) catch {
            _ = app.http_gate.rejected.fetchAdd(1, .acq_rel);
            return;
        };
        defer {
            request_completed.store(true, .release);
            request_deadline.cancel(io);
        }
        app.serve(&req, peer_ip) catch |err| std.log.err("request failed: {t}", .{err});
        return;
    }
    app.serve(&req, peer_ip) catch |err| std.log.err("request failed: {t}", .{err});
}
