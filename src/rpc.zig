//! Newline-delimited JSON-RPC 2.0 framing over any Reader/Writer pair.
//! One JSON value per line; responses are flushed line-by-line.

const std = @import("std");
const json = std.json;
const Io = std.Io;

pub const codes = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
};

pub const Error = struct {
    code: i64,
    message: []const u8,
    data: ?json.Value = null,
};

pub const Request = struct {
    method: []const u8,
    id: ?json.Value, // null => notification: must not be answered
    params: json.Value = .null,
};

pub const Response = union(enum) {
    result: json.Value,
    err: Error,

    pub const ok: Response = .{ .result = .null };
};

pub const Handler = struct {
    ptr: *anyopaque,
    func: *const fn (ptr: *anyopaque, req: Request, out: *Io.Writer) Response,

    pub fn handle(self: Handler, req: Request, out: *Io.Writer) Response {
        return self.func(self.ptr, req, out);
    }
};

pub const ServeError = Io.Writer.Error || Io.Reader.Error || std.mem.Allocator.Error;

/// Reads one LF-terminated line, transparently spanning reader-buffer limits.
/// The slice is valid until the next call. Returns error.EndOfStream only when
/// no bytes remain at all.
fn readLine(alloc: std.mem.Allocator, r: *Io.Reader, acc: *std.ArrayList(u8)) ServeError![]const u8 {
    acc.clearRetainingCapacity();
    while (true) {
        const avail = r.buffered();
        if (std.mem.indexOfScalar(u8, avail, '\n')) |idx| {
            const chunk = try r.take(idx + 1); // includes the newline
            if (acc.items.len == 0) return chunk[0..idx];
            try acc.appendSlice(alloc, chunk[0..idx]);
            return acc.items;
        }
        if (avail.len > 0) {
            try acc.appendSlice(alloc, try r.take(avail.len));
            continue;
        }
        _ = r.peek(1) catch |err| switch (err) {
            error.EndOfStream => {
                if (acc.items.len == 0) return error.EndOfStream;
                return acc.items; // final line without trailing newline
            },
            else => |e| return e,
        };
    }
}

/// Processes requests until the input reader reaches end of stream.
pub fn serve(alloc: std.mem.Allocator, in: *Io.Reader, out: *Io.Writer, handler: Handler) ServeError!void {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    while (true) {
        const line = readLine(alloc, in, &acc) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = json.parseFromSlice(json.Value, alloc, trimmed, .{
            .duplicate_field_behavior = .use_last,
        }) catch {
            try respond(out, .null, .{ .err = .{ .code = codes.parse_error, .message = "parse error" } });
            continue;
        };
        defer parsed.deinit();

        try dispatch(out, handler, parsed.value);
    }
}

fn dispatch(out: *Io.Writer, handler: Handler, msg: json.Value) ServeError!void {
    const obj = switch (msg) {
        .object => |o| o,
        else => return respond(out, .null, .{ .err = .{ .code = codes.invalid_request, .message = "request must be a JSON object" } }),
    };

    const maybe_method = obj.get("method");
    if (maybe_method == null or maybe_method.? != .string) {
        return respond(out, extractId(obj), .{ .err = .{ .code = codes.invalid_request, .message = "missing method" } });
    }
    const req = Request{
        .method = maybe_method.?.string,
        .id = if (obj.get("id")) |id| switch (id) {
            .null => null,
            else => id,
        } else null,
        .params = if (obj.get("params")) |p| p else .null,
    };

    // Batch requests are not part of JSON-RPC 2.0 required behavior for MCP; ignore.
    if (req.id == null) {
        _ = handler.handle(req, out); // Notification: no response regardless of outcome.
        return;
    }
    try respond(out, req.id.?, handler.handle(req, out));
}

fn extractId(obj: json.ObjectMap) json.Value {
    return if (obj.get("id")) |id| id else .null;
}

fn respond(out: *Io.Writer, id: json.Value, resp: Response) ServeError!void {
    var s = json.Stringify{ .writer = out, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    switch (resp) {
        .result => |v| {
            try s.objectField("result");
            try s.write(v);
        },
        .err => |e| {
            try s.objectField("error");
            try s.beginObject();
            try s.objectField("code");
            try s.write(e.code);
            try s.objectField("message");
            try s.write(e.message);
            if (e.data) |d| {
                try s.objectField("data");
                try s.write(d);
            }
            try s.endObject();
        },
    }
    try s.endObject();
    try out.writeByte('\n');
    try out.flush();
}

// ---- tests ----

const TestCtx = struct {
    calls: std.ArrayList(Request),
    alloc: std.mem.Allocator,
    reply: Response,

    fn h(ctx: *anyopaque, req: Request, out_writer: *Io.Writer) Response {
        _ = out_writer;
        const self: *TestCtx = @ptrCast(@alignCast(ctx));
        self.calls.append(self.alloc, .{
            .method = self.alloc.dupe(u8, req.method) catch @panic("oom"),
            .id = req.id,
            .params = req.params,
        }) catch @panic("oom");
        if (std.mem.eql(u8, req.method, "boom")) return .{ .err = .{ .code = codes.internal_error, .message = "kaboom" } };
        return self.reply;
    }
};

fn run(alloc: std.mem.Allocator, input: []const u8, reply: Response) !struct {
    out: []const u8,
    calls: std.ArrayList(Request),
    ctx: TestCtx,
} {
    var ctx = TestCtx{ .calls = .empty, .alloc = alloc, .reply = reply };
    var reader = Io.Reader.fixed(input);
    var out_buf: [64 * 1024]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);
    try serve(alloc, &reader, &writer, .{ .ptr = &ctx, .func = &TestCtx.h });
    return .{ .out = writer.buffer[0..writer.end], .calls = ctx.calls, .ctx = ctx };
}

test "valid request gets result with echoed id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var res = try run(alloc,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}
    , .{ .result = .{ .bool = true } });
    defer res.calls.deinit(alloc);

    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":7,"result":true}
    ++ "\n",
        res.out,
    );
    try std.testing.expectEqual(@as(usize, 1), res.calls.items.len);
    try std.testing.expectEqualStrings("tools/list", res.calls.items[0].method);
}

test "string id is echoed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var res = try run(alloc,
        \\{"jsonrpc":"2.0","id":"abc","method":"x"}
    , .ok);
    defer res.calls.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"id\":\"abc\"") != null);
}

test "notification gets no response but is handled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var res = try run(alloc,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    , .ok);
    defer res.calls.deinit(alloc);
    try std.testing.expectEqualStrings("", res.out);
    try std.testing.expectEqual(@as(usize, 1), res.calls.items.len);
}

test "parse error yields -32700 and stream continues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var res = try run(alloc, "{not json\n" ++
        \\{"jsonrpc":"2.0","id":1,"method":"ok"}
    ++ "\n", .{ .result = .{ .integer = 5 } });
    defer res.calls.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"code\":-32700") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"result\":5") != null);
    try std.testing.expectEqual(@as(usize, 1), res.calls.items.len);
}

test "invalid requests yield -32600" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var res = try run(alloc, "42\n" ++
        \\{"jsonrpc":"2.0","id":2,"params":{}}
    ++ "\n", .ok);
    defer res.calls.deinit(alloc);
    const count = std.mem.count(u8, res.out, "-32600");
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), res.calls.items.len);
}

test "request line larger than reader buffer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var filler: [200_000]u8 = undefined;
    @memset(&filler, 'x');
    const path = "/tmp/swagger-mcp-rpc-bigline.json";
    const content = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"{s}\"}}\n", .{filler[0..]});
    var threaded = Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var wfile = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    try wfile.writeStreamingAll(io, content);
    wfile.close(io);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var in_buf: [4096]u8 = undefined;
    var reader = Io.File.Reader.init(file, io, &in_buf);
    var out_buf: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);

    const ctx = alloc.create(TestCtx) catch return error.OutOfMemory;
    ctx.* = .{ .calls = .empty, .alloc = alloc, .reply = .ok };
    try serve(alloc, &reader.interface, &writer, .{ .ptr = ctx, .func = &TestCtx.h });

    const out = writer.buffer[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":9") != null);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls.items.len);
    try std.testing.expectEqual(@as(usize, 200_000), ctx.calls.items[0].method.len);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "no trailing newline on last line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var res = try run(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tail\"}", .ok);
    defer res.calls.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"id\":1") != null);
}

test "handler error becomes error response" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var res = try run(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"boom"}
    , .ok);
    defer res.calls.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"code\":-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "kaboom") != null);
}
