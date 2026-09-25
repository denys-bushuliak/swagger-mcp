//! Executes an API operation as a real HTTP request.

const std = @import("std");
const json = std.json;
const http = std.http;
const Io = std.Io;
const doc = @import("openapi/parse.zig").doc;
const mcp = @import("mcp.zig");

pub const max_response_bytes = 4 * 1024 * 1024;

pub const Built = struct {
    method: []const u8,
    url: []const u8,
    headers: []const http.Header = &.{},
    body: ?[]const u8 = null,
};

pub const BuildError = error{
    MissingBaseUrl,
    MissingArgument,
    BadArguments,
    NoTemplateParams,
} || std.mem.Allocator.Error;

pub const auth_env_var = "SWAGGER_MCP_TOKEN";

/// Compose method+URL+headers+body from an operation and tool arguments.
/// `token` (optional) is sent as `Authorization: Bearer <token>`.
pub fn buildRequest(
    alloc: std.mem.Allocator,
    base_url: []const u8,
    op: doc.Operation,
    path_template: []const u8,
    args: json.Value,
    token: ?[]const u8,
) BuildError!Built {
    if (base_url.len == 0) return BuildError.MissingBaseUrl;
    const arg_obj = switch (args) {
        .null => json.ObjectMap.empty,
        .object => |o| o,
        else => return BuildError.BadArguments,
    };

    // --- path interpolation ---
    var path_url: std.ArrayList(u8) = .empty;
    var used: std.ArrayList([]const u8) = .empty;
    {
        var i: usize = 0;
        const base_trimmed = std.mem.trim(u8, base_url, "/");
        try path_url.appendSlice(alloc, base_trimmed);
        while (i < path_template.len) {
            if (path_template[i] == ':') {
                const start = i + 1;
                var j = start;
                while (j < path_template.len and path_template[j] != '/') : (j += 1) {}
                const pname = path_template[start..j];
                const val = (try valueToString(alloc, arg_obj.get(pname))) orelse return BuildError.MissingArgument;
                try path_url.appendSlice(alloc, try encodePercent(alloc, val));
                try used.append(alloc, pname);
                i = j;
            } else {
                try path_url.append(alloc, path_template[i]);
                i += 1;
            }
        }
    }

    // --- query ---
    var query: std.ArrayList(u8) = .empty;
    for (op.params) |p| {
        if (p.location != .query) continue;
        const v = arg_obj.get(p.name) orelse continue;
        if (v == .null) continue;
        if (p.collection_format) |cf| {
            if (v == .array and std.mem.eql(u8, cf, "multi")) {
                for (v.array.items) |item| {
                    try query.append(alloc, if (query.items.len == 0) '?' else '&');
                    try query.appendSlice(alloc, try encodePercent(alloc, p.name));
                    try query.append(alloc, '=');
                    try queryAppendValue(alloc, &query, item);
                }
                continue;
            }
        }
        try query.append(alloc, if (query.items.len == 0) '?' else '&');
        try query.appendSlice(alloc, try encodePercent(alloc, p.name));
        try query.append(alloc, '=');
        try queryAppendValue(alloc, &query, v);
    }
    var url = path_url.items;
    if (query.items.len > 0) url = try std.mem.concat(alloc, u8, &.{ path_url.items, query.items });

    // --- headers + body ---
    var headers: std.ArrayList(http.Header) = .empty;
    var content_type: []const u8 = "";
    for (op.params) |p| {
        if (p.location != .header) continue;
        const v = arg_obj.get(p.name) orelse continue;
        if (v == .null) continue;
        const sv = (try valueToString(alloc, v)) orelse return BuildError.BadArguments;
        try headers.append(alloc, .{ .name = p.name, .value = sv });
    }
    if (token) |t| {
        const owned_t = try std.fmt.allocPrint(alloc, "Bearer {s}", .{t});
        try headers.append(alloc, .{ .name = "Authorization", .value = owned_t });
    }

    var body: ?[]const u8 = null;
    for (op.params) |p| {
        switch (p.location) {
            .body => {
                const v = arg_obj.get(p.name) orelse continue;
                if (v == .null) continue;
                var w: Io.Writer.Allocating = .init(alloc);
                json.Stringify.value(v, .{}, &w.writer) catch return error.OutOfMemory;
                body = w.written();
                if (content_type.len == 0) content_type = "application/json";
            },
            .form_data => {
                var form: std.ArrayList(u8) = .empty;
                for (op.params) |fp| {
                    if (fp.location != .form_data) continue;
                    const fv = arg_obj.get(fp.name) orelse continue;
                    if (fv == .null) continue;
                    try appendForm(alloc, &form, fp.name, fv);
                }
                if (form.items.len > 0) {
                    body = form.items;
                    if (content_type.len == 0) content_type = "application/x-www-form-urlencoded";
                }
                break;
            },
            else => {},
        }
    }
    if (content_type.len > 0) try headers.append(alloc, .{ .name = "Content-Type", .value = content_type });

    return .{ .method = op.method, .url = url, .headers = headers.items, .body = body };
}

fn appendForm(alloc: std.mem.Allocator, list: *std.ArrayList(u8), name: []const u8, v: json.Value) !void {
    if (list.items.len > 0) try list.append(alloc, '&');
    try list.appendSlice(alloc, try encodePercent(alloc, name));
    try list.append(alloc, '=');
    try queryAppendValue(alloc, list, v);
}

fn queryAppendValue(alloc: std.mem.Allocator, list: *std.ArrayList(u8), v: json.Value) !void {
    switch (v) {
        .array => |arr| {
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try list.append(alloc, ',');
                try list.appendSlice(alloc, try encodePercent(alloc, (try valueToString(alloc, item)) orelse ""));
            }
        },
        .bool => |b| try list.appendSlice(alloc, if (b) "true" else "false"),
        else => try list.appendSlice(alloc, try encodePercent(alloc, (try valueToString(alloc, v)) orelse "")),
    }
}

fn valueToString(alloc: std.mem.Allocator, v: ?json.Value) !?[]const u8 {
    const vv = v orelse return null;
    return switch (vv) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .bool => |b| if (b) "true" else "false",
        .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .number_string => |s| s,
        else => null,
    };
}

/// Percent-encode everything outside RFC 3986 unreserved set.
pub fn encodePercent(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try out.append(alloc, c),
            else => {
                try out.appendSlice(alloc, "%");
                var hex: [2]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "{X:0>2}", .{c}) catch unreachable;
                try out.append(alloc, hex[0]);
                try out.append(alloc, hex[1]);
            },
        }
    }
    return out.items;
}

pub const ExecError = BuildError || error{ HttpFailed, TooLarge, BodyNotAllowed };

/// Perform the request and return a text MCP tool result.
pub fn execute(
    alloc: std.mem.Allocator,
    io: Io,
    built: Built,
) ExecError!mcp.ToolResult {
    var client = http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(built.url) catch return ExecError.BadArguments;
    const method = std.meta.stringToEnum(http.Method, built.method) orelse return ExecError.BadArguments;

    var all_headers: std.ArrayList(http.Header) = .empty;
    try all_headers.appendSlice(alloc, built.headers);
    try all_headers.append(alloc, .{ .name = "Accept", .value = "application/json, */*" });
    var req = client.request(method, uri, .{
        .extra_headers = all_headers.items,
    }) catch return ExecError.HttpFailed;
    defer req.deinit();

    if (built.body) |b| {
        // Mirror of the sendBodiless guard: std.http sendBodyUnflushed asserts
        // method.requestHasBody(), so a spec that declares a body parameter on
        // GET/DELETE/etc must fail cleanly, not abort the server.
        if (!method.requestHasBody()) return ExecError.BodyNotAllowed;
        const payload = try alloc.dupe(u8, b);
        req.transfer_encoding = .{ .content_length = payload.len };
        req.sendBodyComplete(payload) catch return ExecError.HttpFailed;
    } else if (method.requestHasBody()) {
        // std.http sendBodiless asserts !method.requestHasBody(), which is
        // false for POST/PUT/PATCH; send an explicit empty body instead.
        var empty: [0]u8 = .{};
        req.sendBodyComplete(&empty) catch return ExecError.HttpFailed;
    } else {
        req.sendBodiless() catch return ExecError.HttpFailed;
    }

    var redir_buf: [8 * 1024]u8 = undefined;
    var res = req.receiveHead(&redir_buf) catch return ExecError.HttpFailed;
    const code: u10 = @intFromEnum(res.head.status);

    var body_buf: [16 * 1024]u8 = undefined;
    const body_reader = res.reader(&body_buf);
    var acc: Io.Writer.Allocating = .init(alloc);
    defer acc.deinit();
    var scratch: [16 * 1024]u8 = undefined;
    var limited_reader = Io.Reader.limited(body_reader, .limited(max_response_bytes + 1), &scratch);
    _ = limited_reader.interface.streamRemaining(&acc.writer) catch |err| switch (err) {
        error.WriteFailed => return ExecError.TooLarge,
        else => @as(usize, 0),
    };
    var truncated = false;
    var body_slice = acc.written();
    if (body_slice.len > max_response_bytes) {
        truncated = true;
        body_slice = body_slice[0..max_response_bytes];
    }

    const ok = code >= 200 and code < 300;
    const status_line = std.fmt.allocPrint(
        alloc,
        "HTTP {d}",
        .{code},
    ) catch return ExecError.HttpFailed;
    const tail = if (truncated) "\n\n[response truncated at {d} bytes]" else "";
    const text = if (body_slice.len == 0)
        std.fmt.allocPrint(alloc, "{s}{s}", .{ status_line, tail }) catch return ExecError.HttpFailed
    else if (ok)
        std.fmt.allocPrint(alloc, "{s}\n\n{s}{s}", .{ status_line, body_slice, tail }) catch return ExecError.HttpFailed
    else
        std.fmt.allocPrint(alloc, "{s} (error)\n\n{s}{s}", .{ status_line, body_slice, tail }) catch return ExecError.HttpFailed;

    return .{ .text = text, .is_error = !ok };
}

pub fn envToken() ?[]const u8 {
    const raw = std.c.getenv(auth_env_var) orelse return null;
    if (raw[0] == 0) return null;
    return std.mem.span(raw);
}

// ---- tests ----

const fixture = struct {
    fn simpleOp(alloc: std.mem.Allocator) doc.Operation {
        var params: std.ArrayList(doc.Param) = .empty;
        params.appendSlice(alloc, &.{
            .{ .name = "owner", .location = .path, .required = true, .schema = .{ .string = "string" } },
            .{ .name = "state", .location = .query, .schema = .{ .string = "string" } },
            .{ .name = "page", .location = .query, .schema = .{ .string = "integer" } },
            .{ .name = "X-Token", .location = .header, .schema = .{ .string = "string" } },
            .{ .name = "body", .location = .body },
        }) catch @panic("oom");
        return .{
            .name = "listIssues",
            .operation_id = "listIssues",
            .summary = "",
            .method = "GET",
            .path = "/repos/{owner}/issues",
            .params = params.items,
        };
    }
};

fn parseArgs(alloc: std.mem.Allocator, text: []const u8) !json.Value {
    const p = try json.parseFromSlice(json.Value, alloc, text, .{});
    return p.value;
}

test "buildRequest: path, query, header, body, encoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const op = fixture.simpleOp(alloc);
    const tmpl = try doc.toColonTemplate(alloc, op.path);
    const args = try parseArgs(alloc,
        \\{"owner":"acme/repo","state":"open","page":3,"X-Token":"abc","body":{"a":1},"extra":"ignored"}
    );
    const built = try buildRequest(alloc, "http://api.example/", op, tmpl, args, null);
    try std.testing.expectEqualStrings("GET", built.method);
    try std.testing.expect(std.mem.startsWith(u8, built.url, "http://api.example/repos/acme%2Frepo/issues?"));
    try std.testing.expect(std.mem.indexOf(u8, built.url, "state=open") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.url, "page=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.url, "extra") == null);

    var saw_header = false;
    for (built.headers) |h| {
        if (std.mem.eql(u8, h.name, "X-Token")) {
            saw_header = true;
            try std.testing.expectEqualStrings("abc", h.value);
        }
    }
    try std.testing.expect(saw_header);

    try std.testing.expect(built.body != null);
    try std.testing.expectEqualStrings("{\"a\":1}", built.body.?);
}

test "buildRequest: missing required path param fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const op = fixture.simpleOp(alloc);
    const tmpl = try doc.toColonTemplate(alloc, op.path);
    const args = try parseArgs(alloc, "{\"state\":\"open\"}");
    try std.testing.expectError(BuildError.MissingArgument, buildRequest(alloc, "http://x", op, tmpl, args, null));
}

test "buildRequest: no base url fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const op = fixture.simpleOp(alloc);
    const tmpl = try doc.toColonTemplate(alloc, op.path);
    const args = try parseArgs(alloc, "{\"owner\":\"o\"}");
    try std.testing.expectError(BuildError.MissingBaseUrl, buildRequest(alloc, "", op, tmpl, args, null));
}

test "buildRequest: bearer token appended" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const op = fixture.simpleOp(alloc);
    const tmpl = try doc.toColonTemplate(alloc, op.path);
    const args = try parseArgs(alloc, "{\"owner\":\"o\"}");
    const built = try buildRequest(alloc, "http://x", op, tmpl, args, "secret123");
    var found = false;
    for (built.headers) |h| {
        if (std.mem.eql(u8, h.name, "Authorization") and std.mem.eql(u8, h.value, "Bearer secret123")) found = true;
    }
    try std.testing.expect(found);
}

test "encodePercent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try encodePercent(arena_state.allocator(), "a b/c?d=e&f~g");
    try std.testing.expectEqualStrings("a%20b%2Fc%3Fd%3De%26f~g", got);
}

test "end-to-end: fetch spec over http and execute GET tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var threaded = Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const python_candidates = [_][]const u8{ "/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3" };
    var python: []const u8 = "";
    for (python_candidates) |c| {
        if (std.Io.Dir.cwd().access(io, c, .{})) |_| {
            python = c;
        } else |_| {}
        if (python.len > 0) break;
    }
    if (python.len == 0) return error.SkipZigTest;

    const port: u16 = @intCast(20000 + @mod(std.c.getpid(), 20000));
    const port_str = try std.fmt.allocPrint(alloc, "{d}", .{port});
    const dir = "/tmp/swagger-mcp-e2e";
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    const spec_json = try std.fmt.allocPrint(alloc,
        \\{{"swagger":"2.0","info":{{"title":"t","version":"1"}},"host":"127.0.0.1:{d}","basePath":"","schemes":["http"],"paths":{{"/payload.json":{{"get":{{"operationId":"getPayload","responses":{{"200":{{"description":"ok"}}}}}}}}}}}}
    , .{port});
    {
        var f = try Io.Dir.cwd().createFile(io, dir ++ "/openapi.json", .{ .truncate = true });
        try f.writeStreamingAll(io, spec_json);
        f.close(io);
        var g = try Io.Dir.cwd().createFile(io, dir ++ "/payload.json", .{ .truncate = true });
        try g.writeStreamingAll(io, "{\"hello\": \"world\", \"n\": 42}");
        g.close(io);
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ python, "-m", "http.server", port_str, "--directory", dir },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = 400 * std.time.ns_per_ms }, .clock = .awake } }, io) catch {};

    var reg = try @import("tools.zig").Registry.init(alloc, io);
    var out_buf: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);
    const load_res = try reg.toolset().call("load_spec", .{ .object = blk: {
        var m: json.ObjectMap = .empty;
        try m.put(alloc, "source", .{ .string = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/openapi.json", .{port}) });
        break :blk m;
    } }, &writer);
    try std.testing.expect(!load_res.is_error);

    const call_res = try reg.toolset().call("getPayload", .{ .object = .empty }, &writer);
    try std.testing.expect(!call_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, call_res.text, "HTTP 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_res.text, "world") != null);

    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

test "regression: bodiless PUT/DELETE do not panic sendBodilessUnflushed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var threaded = Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const python_candidates = [_][]const u8{ "/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3" };
    var python: []const u8 = "";
    for (python_candidates) |c| {
        if (std.Io.Dir.cwd().access(io, c, .{})) |_| {
            python = c;
        } else |_| {}
        if (python.len > 0) break;
    }
    if (python.len == 0) return error.SkipZigTest;

    const port: u16 = @intCast(50000 + @mod(std.c.getpid(), 10000));
    const port_str = try std.fmt.allocPrint(alloc, "{d}", .{port});
    const dir = "/tmp/swagger-mcp-bodiless";
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    const spec_json = try std.fmt.allocPrint(alloc,
        \\{{"openapi":"3.0.0","info":{{"title":"t","version":"1"}},"servers":[{{"url":"http://127.0.0.1:{d}"}}],"paths":{{"/collab/{{owner}}/{{repo}}/{{username}}":{{"put":{{"operationId":"putCollab","responses":{{"200":{{"description":"ok"}}}}}},"delete":{{"operationId":"delCollab","responses":{{"204":{{"description":"ok"}}}}}}}},"/delbody":{{"delete":{{"operationId":"delBody","requestBody":{{"required":true,"content":{{"application/json":{{"schema":{{"type":"object"}}}}}},"responses":{{"200":{{"description":"ok"}}}}}}}}}}}}}}
    , .{port});
    const server_py =
        \\import http.server, json, os, sys
        \\class H(http.server.SimpleHTTPRequestHandler):
        \\    def __init__(self, *a, **k):
        \\        super().__init__(*a, directory=os.path.dirname(os.path.abspath(__file__)), **k)
        \\    def log_message(self, *a): pass
        \\    def do_PUT(self):
        \\        n = int(self.headers.get("Content-Length") or -1)
        \\        if n > 0: self.rfile.read(n)
        \\        body = json.dumps({"method": "PUT", "content_length": n}).encode()
        \\        self.send_response(200)
        \\        self.send_header("Content-Type", "application/json")
        \\        self.send_header("Content-Length", str(len(body)))
        \\        self.end_headers()
        \\        self.wfile.write(body)
        \\    def do_DELETE(self):
        \\        n = int(self.headers.get("Content-Length") or -1)
        \\        if n > 0: self.rfile.read(n)
        \\        body = json.dumps({"method": "DELETE", "content_length": n}).encode()
        \\        self.send_response(200)
        \\        self.send_header("Content-Type", "application/json")
        \\        self.send_header("Content-Length", str(len(body)))
        \\        self.end_headers()
        \\        self.wfile.write(body)
        \\http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
    ;
    {
        var f = try Io.Dir.cwd().createFile(io, dir ++ "/openapi.json", .{ .truncate = true });
        try f.writeStreamingAll(io, spec_json);
        f.close(io);
        var g = try Io.Dir.cwd().createFile(io, dir ++ "/server.py", .{ .truncate = true });
        try g.writeStreamingAll(io, server_py);
        g.close(io);
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ python, dir ++ "/server.py", port_str },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = 400 * std.time.ns_per_ms }, .clock = .awake } }, io) catch {};

    var reg = try @import("tools.zig").Registry.init(alloc, io);
    var out_buf: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);
    const load_res = try reg.toolset().call("load_spec", .{ .object = blk: {
        var m: json.ObjectMap = .empty;
        try m.put(alloc, "source", .{ .string = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/openapi.json", .{port}) });
        break :blk m;
    } }, &writer);
    try std.testing.expect(!load_res.is_error);

    const parsed_args = try parseArgs(alloc, "{\"owner\":\"o\",\"repo\":\"r\",\"username\":\"u\"}");

    // Bodiless PUT: std.http sendBodiless asserts !requestHasBody() on PUT.
    const put_res = try reg.toolset().call("putCollab", parsed_args, &writer);
    try std.testing.expect(!put_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, put_res.text, "HTTP 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, put_res.text, "PUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, put_res.text, "\"content_length\": 0") != null);

    const del_res = try reg.toolset().call("delCollab", parsed_args, &writer);
    try std.testing.expect(!del_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, del_res.text, "HTTP 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, del_res.text, "\"content_length\": -1") != null);

    const del_body_args = try parseArgs(alloc, "{\"body\":{\"a\":1}}");
    const del_body_res = try reg.toolset().call("delBody", del_body_args, &writer);
    try std.testing.expect(del_body_res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, del_body_res.text, "does not accept a request body") != null);

    const alive_res = try reg.toolset().call("delCollab", parsed_args, &writer);
    try std.testing.expect(!alive_res.is_error);

    Io.Dir.cwd().deleteTree(io, dir) catch {};
}
