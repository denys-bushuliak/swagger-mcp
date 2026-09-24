//! OpenAPI 3.0/3.1 document -> openapi.Spec model.

const std = @import("std");
const json = std.json;
const doc = @import("doc.zig");

const http_methods = [_][]const u8{ "get", "put", "post", "delete", "options", "head", "patch", "trace" };

pub const ParseError = error{ NotOpenApi3, BadDocument } || std.mem.Allocator.Error;

pub fn parse(alloc: std.mem.Allocator, root: json.Value) ParseError!doc.Spec {
    if (root != .object) return ParseError.BadDocument;
    const obj = root.object;
    const version = obj.get("openapi") orelse return ParseError.NotOpenApi3;
    if (version != .string or !std.mem.startsWith(u8, version.string, "3.")) return ParseError.NotOpenApi3;

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
        const shared_params: json.Value = path_item.object.get("parameters") orelse .null;

        for (http_methods) |method| {
            const op_v = path_item.object.get(method) orelse continue;
            if (op_v != .object) continue;
            var operation = try parseOperation(alloc, root, path_str, method, op_v, shared_params);
            operation.name = try doc.dedupe(alloc, &taken, operation.name);
            try ops.append(alloc, operation);
        }
    }

    return .{ .base_url = base, .operations = ops.items };
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

    // requestBody: pick the first JSON media type.
    if (op.get("requestBody")) |rb_v| {
        const rb = D.resolve(rb_v);
        if (rb == .object) {
            var required = false;
            if (rb.object.get("required")) |r| {
                if (r == .bool) {
                    required = r.bool;
                }
            }
            if (rb.object.get("content")) |content| {
                if (content == .object) {
                    var best: ?json.Value = null;
                    var cit = content.object.iterator();
                    while (cit.next()) |media| {
                        if (std.mem.indexOf(u8, media.key_ptr.*, "json") == null) continue;
                        if (media.value_ptr.* == .object) {
                            best = media.value_ptr.*.object.get("schema");
                            break;
                        }
                    }
                    if (best) |schema| {
                        var stack: std.ArrayList([]const u8) = .empty;
                        try params_list.append(alloc, .{
                            .name = "body",
                            .location = .body,
                            .required = required,
                            .schema = D.expandRefs(alloc, schema, &stack, 0) catch .null,
                        });
                    }
                }
            }
        }
    }

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
        const location = std.meta.stringToEnum(doc.ParamLocation, in_v.string) orelse continue;
        var required = false;
        if (p.object.get("required")) |r| {
            if (r == .bool) {
                required = r.bool;
            }
        }

        var schema: json.Value = .null;
        if (p.object.get("schema")) |s| {
            var stack: std.ArrayList([]const u8) = .empty;
            schema = D.expandRefs(alloc, s, &stack, 0) catch .null;
        }
        try out.append(alloc, .{ .name = name_v.string, .location = location, .required = required, .schema = schema });
    }
}

fn computeBaseUrl(alloc: std.mem.Allocator, obj: json.ObjectMap) ![]const u8 {
    const servers_v = obj.get("servers") orelse return "";
    if (servers_v != .array or servers_v.array.items.len == 0) return "";
    const first = servers_v.array.items[0];
    if (first != .object) return "";
    const url_v = first.object.get("url") orelse return "";
    if (url_v != .string) return "";
    var url = url_v.string;
    if (std.mem.indexOfScalar(u8, url, '{') != null) {
        // Templated server URL: substitute variable defaults.
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < url.len) {
            if (url[i] == '{') {
                const close = std.mem.indexOfScalarPos(u8, url, i, '}') orelse break;
                const var_name = url[i + 1 .. close];
                if (first.object.get("variables")) |vars| {
                    if (vars == .object) {
                        if (vars.object.get(var_name)) |vd| {
                            if (vd == .object) {
                                if (vd.object.get("default")) |dv| {
                                    if (dv == .string) {
                                        try out.appendSlice(alloc, dv.string);
                                        i = close + 1;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }
                try out.appendSlice(alloc, var_name);
                i = close + 1;
            } else {
                try out.append(alloc, url[i]);
                i += 1;
            }
        }
        url = out.items;
    }
    return url;
}
