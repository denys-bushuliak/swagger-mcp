//! Shared document helpers: $ref resolution, parameter/operation models.

const std = @import("std");
const json = std.json;

pub const ParamLocation = enum { path, query, header, cookie, body, form_data };

pub const Param = struct {
    name: []const u8,
    location: ParamLocation,
    required: bool = false,
    /// JSON-Schema fragment describing this parameter's value.
    schema: json.Value = .null,
    /// Swagger 2.0 array serialization hint (csv, multi, ...).
    collection_format: ?[]const u8 = null,
};

pub const Operation = struct {
    /// MCP-safe tool name (sanitized, unique).
    name: []const u8,
    /// Raw operationId from the spec (fallback: derived).
    operation_id: []const u8,
    summary: []const u8,
    method: []const u8, // uppercase
    path: []const u8, // templated path, e.g. /repos/{owner}/{repo}
    params: []const Param,
};

pub const Spec = struct {
    /// Base URL for HTTP execution, empty if unknown (caller decides).
    base_url: []const u8 = "",
    /// Path prefix (Swagger 2.0 basePath) to re-attach when api_base overrides base_url.
    path_prefix: []const u8 = "",
    operations: []const Operation = &.{},
};

pub const Doc = struct {
    root: json.Value,

    pub fn lookup(self: Doc, pointer: []const u8) ?json.Value {
        if (!std.mem.startsWith(u8, pointer, "#/")) return null;
        var current = self.root;
        var it = std.mem.splitScalar(u8, pointer[2..], '/');
        while (it.next()) |raw_token| {
            const token = raw_token;
            switch (current) {
                .object => |obj| {
                    const nxt = obj.get(token) orelse return null;
                    current = nxt;
                },
                .array => |arr| {
                    const idx = std.fmt.parseInt(usize, token, 10) catch return null;
                    if (idx >= arr.items.len) return null;
                    current = arr.items[idx];
                },
                else => return null,
            }
        }
        return current;
    }

    /// If `v` is a `{"$ref": "..."}` object, resolve it (single hop).
    pub fn resolve(self: Doc, v: json.Value) json.Value {
        if (v != .object) return v;
        const r = v.object.get("$ref") orelse return v;
        if (r != .string) return v;
        return self.lookup(r.string) orelse v;
    }

    /// Recursively inline `$ref` objects. Cycles are cut: a repeated ref along
    /// the path stack becomes `{"description": "$ref: <target>"}`.
    pub fn expandRefs(self: Doc, alloc: std.mem.Allocator, v: json.Value, stack: *std.ArrayList([]const u8), depth: usize) !json.Value {
        if (depth > 12) return .{ .string = "..." };
        switch (v) {
            .object => |obj| {
                if (obj.get("$ref")) |r| {
                    if (r == .string) {
                        for (stack.items) |s| {
                            if (std.mem.eql(u8, s, r.string)) {
                                var out: json.ObjectMap = .empty;
                                try out.put(alloc, "description", .{ .string = try std.fmt.allocPrint(alloc, "recursive $ref: {s}", .{r.string}) });
                                return .{ .object = out };
                            }
                        }
                        try stack.append(alloc, r.string);
                        defer _ = stack.pop();
                        const target = self.lookup(r.string) orelse return v;
                        return self.expandRefs(alloc, target, stack, depth + 1);
                    }
                }
                var out: json.ObjectMap = .empty;
                var it = obj.iterator();
                while (it.next()) |e| {
                    const nv = try self.expandRefs(alloc, e.value_ptr.*, stack, depth + 1);
                    try out.put(alloc, e.key_ptr.*, nv);
                }
                return .{ .object = out };
            },
            .array => |arr| {
                var out = json.Array.init(alloc);
                for (arr.items) |item| try out.append(try self.expandRefs(alloc, item, stack, depth + 1));
                return .{ .array = out };
            },
            else => return v,
        }
    }
};

/// Sanitize to MCP tool-name charset ^[a-zA-Z0-9_-]{1,64}$, deterministic.
pub fn sanitizeToolName(alloc: std.mem.Allocator, raw: []const u8, method: []const u8, path: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            try list.append(alloc, c);
        } else if (c == '.' or c == ' ' or c == '/' or c == '{' or c == '}') {
            if (list.items.len > 0 and list.items[list.items.len - 1] != '_') try list.append(alloc, '_');
        }
    }
    while (list.items.len > 0 and (list.items[list.items.len - 1] == '_' or list.items[list.items.len - 1] == '-')) {
        _ = list.pop();
    }
    if (list.items.len == 0) {
        const derived = try std.fmt.allocPrint(alloc, "{s}{s}", .{ method, path });
        return sanitizeToolName(alloc, derived, method, path);
    }
    if (list.items.len > 64) return list.items[0..64];
    return list.items;
}

/// Make `name` unique within `taken` by appending _2, _3, ...
pub fn dedupe(alloc: std.mem.Allocator, taken: *std.StringHashMap(void), name: []const u8) ![]const u8 {
    const gop = try taken.getOrPut(name);
    if (!gop.found_existing) return name;
    var n: usize = 2;
    while (true) {
        const cand = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ name, n });
        const g2 = try taken.getOrPut(cand);
        if (!g2.found_existing) return cand;
        n += 1;
        if (n > 1000) return error.OutOfMemory;
    }
}

pub const PathTemplateError = error{BadTemplate};

/// Convert OpenAPI `{param}` template to `:param` colon form used at runtime.
pub fn toColonTemplate(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, path, i, '}') orelse return PathTemplateError.BadTemplate;
            try out.append(alloc, ':');
            try out.appendSlice(alloc, path[i + 1 .. close]);
            i = close + 1;
        } else {
            try out.append(alloc, path[i]);
            i += 1;
        }
    }
    return out.items;
}

test "Doc.lookup and resolve" {
    const payload =
        \\{"definitions":{"A":{"type":"string"}},"x":{"$ref":"#/definitions/A"}}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const parsed = try json.parseFromSlice(json.Value, alloc, payload, .{});
    const doc = Doc{ .root = parsed.value };
    const r = doc.resolve(doc.root.object.get("x").?);
    try std.testing.expectEqualStrings("string", r.object.get("type").?.string);
    try std.testing.expect(doc.lookup("#/nope") == null);
}

test "expandRefs cuts cycles" {
    const payload =
        \\{"definitions":{"Node":{"properties":{"child":{"$ref":"#/definitions/Node"}},"name":{"type":"string"}}}}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const parsed = try json.parseFromSlice(json.Value, alloc, payload, .{});
    const doc = Doc{ .root = parsed.value };
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);
    const expanded = try doc.expandRefs(alloc, doc.root.object.get("definitions").?.object.get("Node").?, &stack, 0);
    const child = expanded.object.get("properties").?.object.get("child").?;
    const inner = child.object.get("properties").?.object.get("child").?; // one hop inlined, then cycle cut
    try std.testing.expect(std.mem.indexOf(u8, inner.object.get("description").?.string, "recursive") != null);
}

test "sanitizeToolName" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "getActionsRun",
        try sanitizeToolName(alloc, "getActionsRun", "GET", "/x"),
    );
    try std.testing.expectEqualStrings(
        "my_op_1",
        try sanitizeToolName(alloc, "my op/1", "GET", "/x"),
    );
    const gen = try sanitizeToolName(alloc, "@@@", "get", "/things/{id}");
    try std.testing.expectEqualStrings("get_things_id", gen);
}

test "dedupe names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var taken = std.StringHashMap(void).init(alloc);
    try std.testing.expectEqualStrings("foo", try dedupe(alloc, &taken, "foo"));
    try std.testing.expectEqualStrings("foo_2", try dedupe(alloc, &taken, "foo"));
    try std.testing.expectEqualStrings("bar", try dedupe(alloc, &taken, "bar"));
    try std.testing.expectEqualStrings("foo_3", try dedupe(alloc, &taken, "foo"));
}

test "toColonTemplate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "/repos/:owner/:repo/issues",
        try toColonTemplate(arena_state.allocator(), "/repos/{owner}/{repo}/issues"),
    );
}
