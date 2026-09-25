//! Dynamic tool registry: `load_spec` swaps in one MCP tool per API operation.

const std = @import("std");
const json = std.json;
const mcp = @import("mcp.zig");
const doc = @import("openapi/parse.zig").doc;
const parse = @import("openapi/parse.zig");
const specio = @import("specio.zig");

pub const max_operations = 2000;

pub const api_base_env_var = "SWAGGER_MCP_API_BASE";

/// Base URL default from the environment (for MCP client configs), if set.
pub fn envApiBase(alloc: std.mem.Allocator) ?[]const u8 {
    const raw = std.c.getenv(api_base_env_var) orelse return null;
    if (raw[0] == 0) return null;
    return alloc.dupe(u8, std.mem.span(raw)) catch null;
}

pub const Registry = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    defs: std.ArrayList(mcp.ToolDef) = .empty,
    ops: std.ArrayList(StoredOp) = .empty,
    base_url: []const u8 = "",
    /// Used when `load_spec` is called without an explicit `api_base`.
    default_api_base: ?[]const u8 = null,
    spec_loaded: bool = false,
    /// Double-buffered arenas: reloading a spec frees the previous document.
    arenas: [2]std.heap.ArenaAllocator = undefined,
    active: usize = 0,
    /// Scratch for per-call response strings (reset on each tools/call).
    temp: std.heap.ArenaAllocator = undefined,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !Registry {
        var self = Registry{ .alloc = alloc, .io = io };
        self.arenas[0] = .init(alloc);
        self.arenas[1] = .init(alloc);
        self.temp = .init(alloc);
        errdefer {
            self.arenas[0].deinit();
            self.arenas[1].deinit();
            self.temp.deinit();
        }
        try self.defs.append(alloc, try loadSpecToolDef(self.specAlloc()));
        return self;
    }

    pub fn deinit(self: *Registry) void {
        self.defs.deinit(self.alloc);
        self.ops.deinit(self.alloc);
        self.arenas[0].deinit();
        self.arenas[1].deinit();
        self.temp.deinit();
    }

    fn specAlloc(self: *Registry) std.mem.Allocator {
        return self.arenas[self.active].allocator();
    }

    pub const StoredOp = struct {
        op: doc.Operation,
        /// Colon-style template for fast interpolation.
        path_template: []const u8,
    };

    pub const InitError = specio.LoadError || parse.ParseError || std.mem.Allocator.Error || error{TooManyOperations};

    /// (Re)load a spec. On failure the previous registry state is untouched.
    pub fn load(self: *Registry, source: []const u8, api_base: ?[]const u8) InitError!usize {
        const next = self.active ^ 1;
        self.arenas[next].deinit();
        self.arenas[next] = .init(self.alloc);
        const a = self.arenas[next].allocator();

        const bytes = try specio.load(a, self.io, source);
        const parsed = json.parseFromSlice(json.Value, a, bytes, .{
            .duplicate_field_behavior = .use_last,
        }) catch return parse.ParseError.BadDocument;

        const spec = try parse.parseAny(a, parsed.value);
        if (spec.operations.len > max_operations) return error.TooManyOperations;

        var base: []const u8 = "";
        if (api_base orelse self.default_api_base) |ab| {
            base = try std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.trim(u8, ab, "/"), spec.path_prefix });
        } else base = try a.dupe(u8, spec.base_url);

        var defs: std.ArrayList(mcp.ToolDef) = .empty;
        try defs.append(self.alloc, try loadSpecToolDef(a));
        var ops: std.ArrayList(StoredOp) = .empty;
        for (spec.operations) |op| {
            const template = doc.toColonTemplate(a, op.path) catch continue;
            const schema = try buildInputSchema(a, op);
            const desc = try std.fmt.allocPrint(
                a,
                "{s} {s} — {s}\n\napi_call: method={s} path={s}",
                .{ op.method, op.path, op.summary, op.method, op.path },
            );
            try defs.append(self.alloc, .{ .name = op.name, .description = desc, .input_schema = schema });
            try ops.append(self.alloc, .{ .op = op, .path_template = template });
        }

        self.defs.deinit(self.alloc);
        self.ops.deinit(self.alloc);
        self.defs = defs;
        self.ops = ops;
        self.base_url = base;
        self.spec_loaded = true;
        self.active = next;
        return ops.items.len;
    }

    pub fn toolset(self: *Registry) mcp.Toolset {
        return .{ .ptr = self, .listFn = &listImpl, .callFn = &callImpl };
    }

    fn listImpl(ptr: *anyopaque) []const mcp.ToolDef {
        const self: *Registry = @ptrCast(@alignCast(ptr));
        return self.defs.items;
    }

    fn callImpl(ptr: *anyopaque, name: []const u8, args: json.Value, out: *std.Io.Writer) mcp.ToolCallError!mcp.ToolResult {
        const self: *Registry = @ptrCast(@alignCast(ptr));
        _ = self.temp.reset(.retain_capacity);
        if (std.mem.eql(u8, name, "load_spec")) return self.callLoadSpec(args, out);
        if (!self.spec_loaded) return .{ .text = "no spec loaded yet; call load_spec first", .is_error = true };
        var i: usize = 0;
        while (i < self.ops.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.ops.items[i].op.name, name)) return self.callOperation(i, args);
        }
        return error.UnknownTool;
    }

    fn callLoadSpec(self: *Registry, args: json.Value, out: *std.Io.Writer) mcp.ToolCallError!mcp.ToolResult {
        if (args != .object) return error.BadArguments;
        const source_v = args.object.get("source") orelse return error.BadArguments;
        if (source_v != .string or source_v.string.len == 0) return error.BadArguments;
        var api_base: ?[]const u8 = null;
        if (args.object.get("api_base")) |b| {
            if (b == .string and b.string.len > 0) api_base = b.string;
        }
        const n = self.load(source_v.string, api_base) catch |err| {
            const msg = switch (err) {
                error.HttpFailed => "failed to fetch spec URL",
                error.SourceNotFound => "spec path not found",
                error.SourceTooLarge => "spec exceeds size limit",
                error.BadSource => "invalid spec source",
                error.UnsupportedDocument => "not an OpenAPI/Swagger document",
                error.BadDocument => "malformed JSON in spec",
                error.TooManyOperations => "spec has too many operations",
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .text = msg, .is_error = true };
        };
        out.print("{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}}\n", .{}) catch return error.OutOfMemory;
        return .{ .text = try std.fmt.allocPrint(self.temp.allocator(), "loaded {d} operations from {s}", .{ n, source_v.string }) };
    }

    fn callOperation(self: *Registry, idx: usize, args: json.Value) mcp.ToolCallError!mcp.ToolResult {
        const stored = &self.ops.items[idx];
        const built = @import("exec.zig").buildRequest(
            self.temp.allocator(),
            self.base_url,
            stored.op,
            stored.path_template,
            args,
            @import("exec.zig").envToken(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingBaseUrl => return .{ .text = "no base URL: pass api_base to load_spec, set --api-base / " ++ api_base_env_var ++ ", or set one in the spec", .is_error = true },
            error.MissingArgument => return .{ .text = "a required path parameter is missing", .is_error = true },
            error.BadArguments => return .{ .text = "arguments must be a JSON object", .is_error = true },
            error.NoTemplateParams => return .{ .text = "invalid path template", .is_error = true },
        };
        return @import("exec.zig").execute(self.temp.allocator(), self.io, built) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.HttpFailed => .{ .text = "HTTP request failed (connection or protocol error)", .is_error = true },
            error.TooLarge => .{ .text = "response exceeds size limit", .is_error = true },
            error.BodyNotAllowed => .{ .text = "this operation's HTTP method does not accept a request body", .is_error = true },
            error.MissingBaseUrl, error.MissingArgument, error.BadArguments, error.NoTemplateParams => .{ .text = "request build failed", .is_error = true },
        };
    }
};

pub fn loadSpecToolDef(alloc: std.mem.Allocator) !mcp.ToolDef {
    var source: json.ObjectMap = .empty;
    try source.put(alloc, "type", .{ .string = "string" });
    try source.put(alloc, "description", .{ .string = "Path or URL to openapi.json / swagger.json" });

    var api_base: json.ObjectMap = .empty;
    try api_base.put(alloc, "type", .{ .string = "string" });
    try api_base.put(alloc, "description", .{ .string = "Override base URL for API calls (optional; defaults to --api-base / SWAGGER_MCP_API_BASE)" });

    var props: json.ObjectMap = .empty;
    try props.put(alloc, "source", .{ .object = source });
    try props.put(alloc, "api_base", .{ .object = api_base });

    var req = json.Array.init(alloc);
    try req.append(.{ .string = "source" });

    var root: json.ObjectMap = .empty;
    try root.put(alloc, "type", .{ .string = "object" });
    try root.put(alloc, "properties", .{ .object = props });
    try root.put(alloc, "required", .{ .array = req });

    return .{
        .name = "load_spec",
        .description = "Load an OpenAPI/Swagger spec (file path or http(s) URL) and expose one tool per API operation. Replaces any previously loaded tools.",
        .input_schema = .{ .object = root },
    };
}

fn buildInputSchema(alloc: std.mem.Allocator, op: doc.Operation) !json.Value {
    var props: json.ObjectMap = .empty;
    var required = json.Array.init(alloc);
    for (op.params) |p| {
        var one: json.ObjectMap = if (p.schema == .object) blk: {
            break :blk p.schema.object;
        } else .empty;
        try one.put(alloc, "description", .{ .string = try std.fmt.allocPrint(alloc, "parameter in {s}", .{locName(p.location)}) });
        try props.put(alloc, p.name, .{ .object = one });
        if (p.required) try required.append(.{ .string = p.name });
    }
    var root: json.ObjectMap = .empty;
    try root.put(alloc, "type", .{ .string = "object" });
    try root.put(alloc, "properties", .{ .object = props });
    try root.put(alloc, "required", .{ .array = required });
    return .{ .object = root };
}

fn locName(l: doc.ParamLocation) []const u8 {
    return switch (l) {
        .path => "path",
        .query => "query",
        .header => "header",
        .cookie => "cookie",
        .body => "request body (JSON)",
        .form_data => "form field",
    };
}

/// Fuzz entry point (EPIC F1): run the parse -> tool-generation pipeline over
/// arbitrary bytes. Malformed documents are NOT failures (errors swallowed);
/// crashes/panics/invariant violations are. Used by `zig build test --fuzz`
/// (native coverage fuzzer) and by src/fuzz_target.zig (AFL++ QEMU mode).
pub fn fuzzSpec(alloc: std.mem.Allocator, bytes: []const u8) void {
    const parsed = json.parseFromSlice(json.Value, alloc, bytes, .{
        .duplicate_field_behavior = .use_last,
    }) catch return;
    const spec = parse.parseAny(alloc, parsed.value) catch return;
    if (spec.operations.len > max_operations) return;

    var taken = std.StringHashMap(void).init(alloc);
    defer taken.deinit();
    for (spec.operations) |op| {
        if (op.name.len == 0) @panic("fuzz: empty tool name");
        const gop = taken.getOrPut(op.name) catch return;
        if (gop.found_existing) @panic("fuzz: duplicate tool name");
        _ = doc.toColonTemplate(alloc, op.path) catch {};
        _ = buildInputSchema(alloc, op) catch return; // OOM only
    }
}

// ---- tests ----

const petstore2_src = @embedFile("fixtures/petstore-swagger2.json");

fn writeTemp(alloc: std.mem.Allocator, io: std.Io, name: []const u8, content: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/{s}", .{name});
    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    try f.writeStreamingAll(io, content);
    f.close(io);
    return path;
}

fn makeRegistry(alloc: std.mem.Allocator, io: std.Io) !Registry {
    const reg = try Registry.init(alloc, io);
    return reg;
}

test "registry starts with only load_spec" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var reg = try makeRegistry(alloc, threaded.io());
    const defs = reg.toolset().list();
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("load_spec", defs[0].name);
}

test "load_spec via tools/call swaps in generated tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try writeTemp(alloc, io, "swagger-mcp-tools-test-swagger2.json", petstore2_src);

    var reg = try makeRegistry(alloc, io);
    var server = mcp.Server.init(alloc, reg.toolset());

    var load_args: json.ObjectMap = .empty;
    try load_args.put(alloc, "source", .{ .string = path });
    var out_buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const res = server.handle(.{
        .method = "tools/call",
        .id = .{ .integer = 1 },
        .params = .{ .object = blk: {
            var m: json.ObjectMap = .empty;
            try m.put(alloc, "name", .{ .string = "load_spec" });
            try m.put(alloc, "arguments", .{ .object = load_args });
            break :blk m;
        } },
    }, &writer);

    switch (res) {
        .result => |v| {
            const content = v.object.get("content").?.array.items;
            try std.testing.expect(content[0].object.get("text").?.string.len > 0);
            try std.testing.expectEqual(false, v.object.get("isError").?.bool);
        },
        else => return error.TestUnexpectedResult,
    }

    // list_changed notification precedes the response on the wire:
    const written = writer.buffer[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "notifications/tools/list_changed") != null);

    // generated tools now visible:
    const defs = reg.toolset().list();
    try std.testing.expectEqual(@as(usize, 7), defs.len); // load_spec + 6 ops
    var saw_update = false;
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, "updatePet")) {
            saw_update = true;
            const props = d.input_schema.object.get("properties").?;
            try std.testing.expect(props.object.get("body") != null);
        }
    }
    try std.testing.expect(saw_update);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "load_spec failure keeps previous state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var reg = try makeRegistry(alloc, threaded.io());

    const before = reg.defs.items.len;
    var out_buf: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const result: mcp.ToolResult = reg.toolset().call("load_spec", .{ .object = blk: {
        var m: json.ObjectMap = .empty;
        try m.put(alloc, "source", .{ .string = "/tmp/definitely-missing-7c1f.json" });
        break :blk m;
    } }, &writer) catch return error.TestUnexpectedResult;
    try std.testing.expect(result.is_error);
    try std.testing.expect(result.text.len > 0);
    try std.testing.expectEqual(before, reg.defs.items.len);
}

test "default_api_base: configured default applies, explicit arg wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try writeTemp(alloc, io, "swagger-mcp-apibase.json", petstore2_src);
    var reg = try makeRegistry(alloc, io);
    reg.default_api_base = "http://api.override/";
    try std.testing.expectEqual(@as(usize, 6), try reg.load(path, null));
    try std.testing.expectEqualStrings("http://api.override/v2", reg.base_url);

    try std.testing.expectEqual(@as(usize, 6), try reg.load(path, "http://explicit/"));
    try std.testing.expectEqualStrings("http://explicit/v2", reg.base_url);

    reg.deinit();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "reload replaces tools and frees old arena" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p1 = try writeTemp(alloc, io, "swagger-mcp-reload-a.json", petstore2_src);
    const p2 = try writeTemp(alloc, io, "swagger-mcp-reload-b.json",
        \\{"swagger":"2.0","info":{"title":"b","version":"1"},"paths":{"/z":{"get":{"operationId":"onlyOp"}}}}
    );
    var reg = try makeRegistry(alloc, io);
    const n1 = try reg.load(p1, null);
    try std.testing.expectEqual(@as(usize, 6), n1);
    const n2 = try reg.load(p2, null);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqual(@as(usize, 2), reg.toolset().list().len); // load_spec + onlyOp
    reg.deinit();
    std.Io.Dir.cwd().deleteFile(io, p1) catch {};
    std.Io.Dir.cwd().deleteFile(io, p2) catch {};
}
