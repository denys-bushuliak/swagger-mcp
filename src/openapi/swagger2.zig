//! Swagger 2.0 document -> openapi.Spec model.

const std = @import("std");
const json = std.json;
const doc = @import("doc.zig");

const http_methods = [_][]const u8{ "get", "put", "post", "delete", "options", "head", "patch" };

pub const ParseError = error{ NotSwagger2, BadDocument } || std.mem.Allocator.Error;

pub fn parse(alloc: std.mem.Allocator, root: json.Value) ParseError!doc.Spec {
    if (root != .object) return ParseError.BadDocument;
    const obj = root.object;
    const version = obj.get("swagger") orelse return ParseError.NotSwagger2;
    if (version != .string or !std.mem.startsWith(u8, version.string, "2.")) return ParseError.NotSwagger2;

    const base = try computeBaseUrl(alloc, obj);

    const paths_v = obj.get("paths") orelse return ParseError.BadDocument;
    if (paths_v != .object) return ParseError.BadDocument;

    var ops: std.ArrayList(doc.Operation) = .empty;
    errdefer ops.deinit(alloc);
    var taken: std.StringHashMap(void) = .init(alloc);

    var pit = paths_v.object.iterator();
    while (pit.next()) |path_entry| {
        const path_str = path_entry.key_ptr.*;
        var path_item = path_entry.value_ptr.*;
        if (path_item == .object and path_item.object.get("$ref") != null) {
            path_item = (doc.Doc{ .root = root }).resolve(path_item);
        }
        if (path_item != .object) continue;

        // Path-level parameters apply to all operations under it.
        const shared_params: json.Value = path_item.object.get("parameters") orelse .null;

        for (http_methods) |method| {
            const op_v = path_item.object.get(method) orelse continue;
            if (op_v != .object) continue;
            var operation = try parseOperation(alloc, root, path_str, method, op_v, shared_params);
            operation.name = try doc.dedupe(alloc, &taken, operation.name);
            try ops.append(alloc, operation);
        }
    }

    return .{ .base_url = base, .path_prefix = normalizePrefix(alloc, obj) catch "", .operations = ops.items };
}

fn parseOperation(
    alloc: std.mem.Allocator,
    root: json.Value,
    path_str: []const u8,
    method: []const u8,
    op_v: json.Value,
    shared_params: json.Value,
) !doc.Operation {
    const D = doc.Doc{ .root = root };
    const op = op_v.object;

    var raw_id: []const u8 = "";
    if (op.get("operationId")) |v| {
        if (v == .string) {
            raw_id = v.string;
        }
    }

    const name = try doc.sanitizeToolName(alloc, raw_id, method, path_str);
    const operation_id = if (raw_id.len > 0) raw_id else name;

    var summary: []const u8 = "";
    if (op.get("summary")) |v| {
        if (v == .string) {
            summary = v.string;
        }
    }

    var params_list: std.ArrayList(doc.Param) = .empty;

    try collectParams(alloc, D, &params_list, shared_params);
    if (op.get("parameters")) |ps| try collectParams(alloc, D, &params_list, ps);

    return .{
        .name = name,
        .operation_id = operation_id,
        .summary = summary,
        .method = std.ascii.upperString(try alloc.alloc(u8, method.len), method),
        .path = path_str,
        .params = params_list.items,
    };
}

fn collectParams(alloc: std.mem.Allocator, D: doc.Doc, out: *std.ArrayList(doc.Param), params_v: json.Value) !void {
    if (params_v != .array) return;
    for (params_v.array.items) |raw| {
        const p = D.resolve(raw);
        if (p != .object) continue;
        const name_v = p.object.get("name") orelse continue;
        if (name_v != .string) continue;
        const in_v = p.object.get("in") orelse continue;
        if (in_v != .string) continue;
        const location = std.meta.stringToEnum(doc.ParamLocation, in_v.string) orelse
            (if (std.mem.eql(u8, in_v.string, "formData")) doc.ParamLocation.form_data else continue);
        var required = false;
        if (p.object.get("required")) |r| {
            if (r == .bool) {
                required = r.bool;
            }
        }

        var schema: json.Value = .null;
        if (location == .body) {
            schema = p.object.get("schema") orelse .null;
        } else {
            // Inline the simple-type fields into a JSON-Schema fragment.
            var s: json.ObjectMap = .empty;
            if (p.object.get("type")) |t| try s.put(alloc, "type", t);
            if (p.object.get("format")) |f| try s.put(alloc, "format", f);
            if (p.object.get("enum")) |e| try s.put(alloc, "enum", e);
            if (p.object.get("default")) |d| try s.put(alloc, "default", d);
            if (p.object.get("items")) |it| {
                var stack: std.ArrayList([]const u8) = .empty;
                try s.put(alloc, "items", try D.expandRefs(alloc, it, &stack, 0));
            }
            schema = .{ .object = s };
        }
        if (schema == .object and schema.object.count() == 0) schema = .null;

        var cf: ?[]const u8 = null;
        if (p.object.get("collectionFormat")) |c| {
            if (c == .string) {
                cf = c.string;
            }
        }

        try out.append(alloc, .{
            .name = name_v.string,
            .location = location,
            .required = required,
            .schema = if (location == .body) blk: {
                var stack: std.ArrayList([]const u8) = .empty;
                break :blk D.expandRefs(alloc, schema, &stack, 0) catch .null;
            } else schema,
            .collection_format = cf,
        });
    }
}

fn normalizePrefix(alloc: std.mem.Allocator, obj: json.ObjectMap) ![]const u8 {
    var base_path: []const u8 = "";
    if (obj.get("basePath")) |b| {
        if (b == .string) base_path = b.string;
    }
    base_path = std.mem.trim(u8, base_path, "/");
    if (base_path.len == 0) return "";
    return try std.fmt.allocPrint(alloc, "/{s}", .{base_path});
}

fn computeBaseUrl(alloc: std.mem.Allocator, obj: json.ObjectMap) ![]const u8 {
    const host_v = obj.get("host");
    if (host_v == null or host_v.? != .string or host_v.?.string.len == 0) return "";
    const host = host_v.?.string;

    var scheme: []const u8 = "https";
    if (obj.get("schemes")) |s| {
        if (s == .array and s.array.items.len > 0 and s.array.items[0] == .string) scheme = s.array.items[0].string;
    }

    var base_path: []const u8 = "";
    if (obj.get("basePath")) |b| {
        if (b == .string) {
            base_path = b.string;
        }
    }
    if (std.mem.eql(u8, base_path, "/")) base_path = "";

    return std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, host, base_path });
}
