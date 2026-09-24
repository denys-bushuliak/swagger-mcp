//! Version-dispatching entry point: parse a spec document of any supported kind.

const std = @import("std");
const json = std.json;

pub const doc = @import("doc.zig");
pub const swagger2 = @import("swagger2.zig");
pub const openapi3 = @import("openapi3.zig");

pub const ParseError = error{ UnsupportedDocument, BadDocument } || std.mem.Allocator.Error;

const fixtures_test = @import("fixtures_test.zig");

test {
    std.testing.refAllDecls(fixtures_test);
}

pub fn parseAny(alloc: std.mem.Allocator, root: json.Value) ParseError!doc.Spec {
    if (root == .object) {
        if (root.object.get("swagger") != null) {
            return swagger2.parse(alloc, root) catch |err| switch (err) {
                error.NotSwagger2 => error.UnsupportedDocument,
                else => |e| return e,
            };
        }
        if (root.object.get("openapi") != null) {
            return openapi3.parse(alloc, root) catch |err| switch (err) {
                error.NotOpenApi3 => error.UnsupportedDocument,
                else => |e| return e,
            };
        }
    }
    return error.UnsupportedDocument;
}

pub fn isSupportedJson(root: json.Value) bool {
    if (root != .object) return false;
    return root.object.get("swagger") != null or root.object.get("openapi") != null;
}

test "dispatches by version key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const s2 = try json.parseFromSlice(json.Value, alloc,
        \\{"swagger":"2.0","info":{"title":"t","version":"1"},"paths":{"/a":{"get":{"operationId":"getA"}}}}
    , .{});
    const spec2 = try parseAny(alloc, s2.value);
    try std.testing.expectEqual(@as(usize, 1), spec2.operations.len);
    try std.testing.expectEqualStrings("getA", spec2.operations[0].name);

    const o3 = try json.parseFromSlice(json.Value, alloc,
        \\{"openapi":"3.0.1","info":{"title":"t","version":"1"},"paths":{"/a":{"post":{"operationId":"postA","requestBody":{"content":{"application/json":{"schema":{"type":"object"}}}}}}}}
    , .{});
    const spec3 = try parseAny(alloc, o3.value);
    try std.testing.expectEqual(@as(usize, 1), spec3.operations.len);
    try std.testing.expectEqualStrings("POST", spec3.operations[0].method);
    try std.testing.expectEqual(@as(usize, 1), spec3.operations[0].params.len);

    const nope = try json.parseFromSlice(json.Value, alloc, "{\"hello\":1}", .{});
    try std.testing.expectError(error.UnsupportedDocument, parseAny(alloc, nope.value));
}
