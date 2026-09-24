//! MCP (Model Context Protocol) server framing on top of rpc.zig.
//! Implements: initialize, initialized, ping, tools/list, tools/call.
//! Tools are supplied by a Toolset implementation (see tools.zig for the live one).

const std = @import("std");
const json = std.json;
const rpc = @import("rpc.zig");

pub const protocol_version = "2025-06-18";
const supported_versions = [_][]const u8{ "2025-06-18", "2024-11-05" };

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: json.Value,
};

pub const ToolResult = struct {
    text: []const u8,
    is_error: bool = false,
};

pub const ToolCallError = error{ UnknownTool, BadArguments, OutOfMemory };

pub const Toolset = struct {
    ptr: *anyopaque,
    listFn: *const fn (ptr: *anyopaque) []const ToolDef,
    callFn: *const fn (ptr: *anyopaque, name: []const u8, args: json.Value, out: *std.Io.Writer) ToolCallError!ToolResult,

    pub fn list(self: Toolset) []const ToolDef {
        return self.listFn(self.ptr);
    }

    pub fn call(self: Toolset, name: []const u8, args: json.Value, out: *std.Io.Writer) ToolCallError!ToolResult {
        return self.callFn(self.ptr, name, args, out);
    }
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    toolset: Toolset,
    client_protocol_version: []const u8 = protocol_version,
    resp: std.heap.ArenaAllocator = undefined,

    pub fn init(alloc: std.mem.Allocator, toolset: Toolset) Server {
        return .{ .alloc = alloc, .toolset = toolset, .resp = .init(alloc) };
    }

    pub fn handle(self: *Server, req: rpc.Request, out: *std.Io.Writer) rpc.Response {
        _ = self.resp.reset(.retain_capacity);
        if (std.mem.eql(u8, req.method, "initialize")) return self.initialize(req);
        if (std.mem.eql(u8, req.method, "ping")) return rpc.Response.ok;
        if (std.mem.eql(u8, req.method, "tools/list")) return self.toolsList();
        if (std.mem.eql(u8, req.method, "tools/call")) return self.toolsCall(req, out);
        if (std.mem.eql(u8, req.method, "notifications/initialized")) return rpc.Response.ok;
        return .{ .err = .{
            .code = rpc.codes.method_not_found,
            .message = "method not found",
            .data = null,
        } };
    }

    fn initialize(self: *Server, req: rpc.Request) rpc.Response {
        const alloc = self.resp.allocator();
        if (req.params == .object) {
            if (req.params.object.get("protocolVersion")) |pv| {
                if (pv == .string) {
                    var matched = false;
                    for (supported_versions) |sup| {
                        if (std.mem.eql(u8, pv.string, sup)) {
                            self.client_protocol_version = sup;
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) self.client_protocol_version = protocol_version;
                }
            }
        }
        return .{ .result = .{ .object = build(alloc, &.{
            .{ "protocolVersion", .{ .string = self.client_protocol_version } },
            .{ "capabilities", .{ .object = build(alloc, &.{
                .{ "tools", .{ .object = build(alloc, &.{.{ "listChanged", .{ .bool = true } }}) } },
            }) } },
            .{ "serverInfo", .{ .object = build(alloc, &.{
                .{ "name", .{ .string = "swagger-mcp" } },
                .{ "version", .{ .string = "0.1.0" } },
            }) } },
        }) } };
    }

    fn toolsList(self: *Server) rpc.Response {
        const alloc = self.resp.allocator();
        var tools = json.Array.init(alloc);
        for (self.toolset.list()) |t| {
            tools.append(.{ .object = build(alloc, &.{
                .{ "name", .{ .string = t.name } },
                .{ "description", .{ .string = t.description } },
                .{ "inputSchema", t.input_schema },
            }) }) catch {};
        }
        return .{ .result = .{ .object = build(alloc, &.{
            .{ "tools", .{ .array = tools } },
        }) } };
    }

    fn toolsCall(self: *Server, req: rpc.Request, out: *std.Io.Writer) rpc.Response {
        const alloc = self.resp.allocator();
        const params = switch (req.params) {
            .object => |o| o,
            else => return .{ .err = .{ .code = rpc.codes.invalid_params, .message = "tools/call params must be an object" } },
        };
        const name_v = params.get("name") orelse return .{ .err = .{ .code = rpc.codes.invalid_params, .message = "missing tool name" } };
        if (name_v != .string) return .{ .err = .{ .code = rpc.codes.invalid_params, .message = "tool name must be a string" } };
        const args: json.Value = params.get("arguments") orelse .null;

        const result = self.toolset.call(name_v.string, args, out) catch |err| switch (err) {
            error.UnknownTool => return .{ .err = .{
                .code = rpc.codes.invalid_params,
                .message = "unknown tool",
                .data = .{ .object = build(alloc, &.{.{ "tool", .{ .string = name_v.string } }}) },
            } },
            error.BadArguments => return .{ .result = contentResult(alloc, "invalid arguments", true) },
            error.OutOfMemory => return .{ .err = .{ .code = rpc.codes.internal_error, .message = "out of memory" } },
        };
        return .{ .result = .{ .object = build(alloc, &.{
            .{ "content", .{ .array = contentArray(alloc, result.text) } },
            .{ "isError", .{ .bool = result.is_error } },
        }) } };
    }
};

fn contentArray(alloc: std.mem.Allocator, text: []const u8) json.Array {
    var arr = json.Array.init(alloc);
    arr.append(.{ .object = build(alloc, &.{
        .{ "type", .{ .string = "text" } },
        .{ "text", .{ .string = text } },
    }) }) catch {};
    return arr;
}

fn contentResult(alloc: std.mem.Allocator, text: []const u8, is_error: bool) json.Value {
    return .{ .object = build(alloc, &.{
        .{ "content", .{ .array = contentArray(alloc, text) } },
        .{ "isError", .{ .bool = is_error } },
    }) };
}

const Field = struct { []const u8, json.Value };

fn build(alloc: std.mem.Allocator, fields: []const Field) json.ObjectMap {
    var map: json.ObjectMap = .empty;
    for (fields) |f| map.put(alloc, f[0], f[1]) catch {};
    return map;
}

pub fn callTestBridge(server: *Server) rpc.Handler {
    return .{ .ptr = server, .func = &handleShim };
}

fn handleShim(ptr: *anyopaque, req: rpc.Request, out: *std.Io.Writer) rpc.Response {
    const self: *Server = @ptrCast(@alignCast(ptr));
    return self.handle(req, out);
}

// ---- tests ----

const StubTools = struct {
    tools: []const ToolDef,
    fn listFn(ptr: *anyopaque) []const ToolDef {
        const self: *StubTools = @ptrCast(@alignCast(ptr));
        return self.tools;
    }
    fn callFn(ptr: *anyopaque, name: []const u8, args: json.Value, out: *std.Io.Writer) ToolCallError!ToolResult {
        _ = ptr;
        _ = args;
        _ = out;
        if (std.mem.eql(u8, name, "echo")) return .{ .text = "hi" };
        return error.UnknownTool;
    }
};

test "initialize handshake negotiates version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var stub = StubTools{ .tools = &.{} };
    var server = Server.init(alloc, toolsetOf(&stub));
    const res = serverHandle(&server, .{
        .method = "initialize",
        .id = .{ .integer = 1 },
        .params = .{ .object = build(alloc, &.{
            .{ "protocolVersion", .{ .string = "2024-11-05" } },
            .{ "capabilities", .{ .object = json.ObjectMap.empty } },
            .{ "clientInfo", .{ .object = json.ObjectMap.empty } },
        }) },
    });
    switch (res) {
        .result => |v| {
            try std.testing.expectEqualStrings("2024-11-05", v.object.get("protocolVersion").?.string);
            try std.testing.expect(v.object.get("capabilities").?.object.get("tools").?.object.get("listChanged").?.bool);
            try std.testing.expectEqualStrings("swagger-mcp", v.object.get("serverInfo").?.object.get("name").?.string);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "unknown protocol version falls back to ours" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var stub = StubTools{ .tools = &.{} };
    var server = Server.init(alloc, toolsetOf(&stub));
    const res = serverHandle(&server, .{
        .method = "initialize",
        .id = .{ .integer = 1 },
        .params = .{ .object = build(alloc, &.{.{ "protocolVersion", .{ .string = "1999-01-01" } }}) },
    });
    switch (res) {
        .result => |v| try std.testing.expectEqualStrings(protocol_version, v.object.get("protocolVersion").?.string),
        else => return error.TestUnexpectedResult,
    }
}

test "tools/list exposes registered tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var defs = [_]ToolDef{.{
        .name = "echo",
        .description = "say hi",
        .input_schema = .{ .object = build(alloc, &.{
            .{ "type", .{ .string = "object" } },
            .{ "properties", .{ .object = json.ObjectMap.empty } },
        }) },
    }};
    var stub = StubTools{ .tools = &defs };
    var server = Server.init(alloc, toolsetOf(&stub));
    const res = serverHandle(&server, .{ .method = "tools/list", .id = .{ .integer = 2 } });
    const tools = res.result.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("echo", tools[0].object.get("name").?.string);
}

test "tools/call dispatches to toolset and wraps text content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var defs = [_]ToolDef{.{
        .name = "echo",
        .description = "d",
        .input_schema = .{ .object = json.ObjectMap.empty },
    }};
    var stub = StubTools{ .tools = &defs };
    var server = Server.init(alloc, toolsetOf(&stub));
    const res = serverHandle(&server, .{
        .method = "tools/call",
        .id = .{ .integer = 3 },
        .params = .{ .object = build(alloc, &.{
            .{ "name", .{ .string = "echo" } },
            .{ "arguments", .{ .object = json.ObjectMap.empty } },
        }) },
    });
    const content = res.result.object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("hi", content[0].object.get("text").?.string);
    try std.testing.expectEqual(false, res.result.object.get("isError").?.bool);
}

test "tools/call unknown tool is a protocol error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var stub = StubTools{ .tools = &.{} };
    var server = Server.init(alloc, toolsetOf(&stub));
    const res = serverHandle(&server, .{
        .method = "tools/call",
        .id = .{ .integer = 4 },
        .params = .{ .object = build(alloc, &.{.{ "name", .{ .string = "nope" } }}) },
    });
    switch (res) {
        .err => |e| try std.testing.expectEqual(rpc.codes.invalid_params, e.code),
        else => return error.TestUnexpectedResult,
    }
}

test "ping ok, unknown method -32601" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var stub = StubTools{ .tools = &.{} };
    var server = Server.init(arena_state.allocator(), toolsetOf(&stub));
    switch (serverHandle(&server, .{ .method = "ping", .id = .{ .integer = 5 } })) {
        .result => {},
        else => return error.TestUnexpectedResult,
    }
    switch (serverHandle(&server, .{ .method = "foo/bar", .id = .{ .integer = 6 } })) {
        .err => |e| try std.testing.expectEqual(rpc.codes.method_not_found, e.code),
        else => return error.TestUnexpectedResult,
    }
}

test "full rpc.serve loop with mcp.Server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var stub = StubTools{ .tools = &.{} };
    var server = Server.init(alloc, toolsetOf(&stub));

    const input =
        \\{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ++ "\n" ++
        \\{"jsonrpc":"2.0","method":"tools/list","id":2}
    ++ "\n";
    var reader = std.Io.Reader.fixed(input);
    var out_buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try @import("rpc.zig").serve(alloc, &reader, &writer, callTestBridge(&server));

    const out = writer.buffer[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":2") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, std.mem.trim(u8, out, "\n"), "\n"));
}

const NullWriter = struct {
    var buf: [8192]u8 = undefined;
};

fn serverHandle(server: *Server, req: rpc.Request) rpc.Response {
    var w = std.Io.Writer.fixed(&NullWriter.buf);
    return server.handle(req, &w);
}

fn toolsetOf(stub: *StubTools) Toolset {
    return .{ .ptr = stub, .listFn = &StubTools.listFn, .callFn = &StubTools.callFn };
}
