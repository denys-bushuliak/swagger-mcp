//! Parser tests against real-format fixtures (embedded, no IO).

const std = @import("std");
const json = std.json;
const doc = @import("doc.zig");
const swagger2 = @import("swagger2.zig");
const openapi3 = @import("openapi3.zig");

const petstore2 = @embedFile("../fixtures/petstore-swagger2.json");
const petstore3 = @embedFile("../fixtures/petstore-openapi3.json");

fn parse(alloc: std.mem.Allocator, src: []const u8) !json.Parsed(json.Value) {
    return json.parseFromSlice(json.Value, alloc, src, .{ .duplicate_field_behavior = .use_last });
}

fn findOp(spec: doc.Spec, name: []const u8) ?doc.Operation {
    for (spec.operations) |op| {
        if (std.mem.eql(u8, op.name, name)) return op;
    }
    return null;
}

test "swagger2 fixture: operations, params, refs, base url" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const parsed = try parse(alloc, petstore2);
    const spec = try swagger2.parse(alloc, parsed.value);

    try std.testing.expectEqualStrings("https://petstore.swagger.io/v2", spec.base_url);
    try std.testing.expectEqual(@as(usize, 6), spec.operations.len);

    const get = findOp(spec, "getPetById").?;
    try std.testing.expectEqualStrings("GET", get.method);
    try std.testing.expectEqualStrings("/pet/{petId}", get.path);
    try std.testing.expectEqual(@as(usize, 1), get.params.len); // inherited path param
    try std.testing.expectEqual(doc.ParamLocation.path, get.params[0].location);
    try std.testing.expect(get.params[0].required);

    const del = findOp(spec, "deletePet").?;
    try std.testing.expectEqual(@as(usize, 2), del.params.len); // header + inherited
    var saw_header = false;
    for (del.params) |p| {
        if (p.location == .header) saw_header = true;
    }
    try std.testing.expect(saw_header);

    const form = findOp(spec, "updatePetWithForm").?;
    try std.testing.expectEqual(@as(usize, 3), form.params.len); // inherited petId + 2 formData
    try std.testing.expectEqual(doc.ParamLocation.path, form.params[0].location);
    try std.testing.expectEqual(doc.ParamLocation.form_data, form.params[1].location);

    const body = findOp(spec, "updatePet").?;
    try std.testing.expectEqual(@as(usize, 1), body.params.len);
    try std.testing.expectEqual(doc.ParamLocation.body, body.params[0].location);
    const pet_schema = body.params[0].schema.object;
    try std.testing.expectEqualStrings("object", pet_schema.get("type").?.string);
    const cat = pet_schema.get("properties").?.object.get("category").?.object;
    try std.testing.expectEqualStrings("object", cat.get("type").?.string); // $ref expanded
    try std.testing.expect(cat.get("properties").?.object.get("name") != null);

    const q = findOp(spec, "findPetsByStatus").?;
    try std.testing.expectEqualStrings("csv", q.params[0].collection_format.?);

    const gen = findOp(spec, "get_owner_owner_pet_petId");
    try std.testing.expect(gen != null); // auto-named operation
}

test "live Forgejo spec (opt-in via SWAGGER_MCP_SPEC=/path)" {
    const raw = std.c.getenv("SWAGGER_MCP_SPEC") orelse return error.SkipZigTest;
    if (raw[0] == 0) return error.SkipZigTest;
    const path = std.mem.span(raw);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const bytes = try @import("../specio.zig").load(std.testing.allocator, threaded.io(), path);
    defer std.testing.allocator.free(bytes);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const parsed = try json.parseFromSlice(json.Value, alloc, bytes, .{ .duplicate_field_behavior = .use_last });
    const spec = try swagger2.parse(alloc, parsed.value);
    try std.testing.expect(spec.operations.len > 400);
    for (spec.operations) |op| {
        try std.testing.expect(op.name.len > 0 and op.name.len <= 64);
        for (op.name) |c| {
            try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '_' or c == '-');
        }
    }
}

test "openapi3 fixture: servers template, requestBody, param refs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const parsed = try parse(alloc, petstore3);
    const spec = try openapi3.parse(alloc, parsed.value);

    try std.testing.expectEqualStrings("https://eu.petstore.example.com/v3", spec.base_url);
    try std.testing.expectEqual(@as(usize, 3), spec.operations.len);

    const del = findOp(spec, "deletePet").?;
    try std.testing.expectEqual(@as(usize, 2), del.params.len); // api_key + $ref'd PetId
    var petid_required = false;
    for (del.params) |p| {
        if (std.mem.eql(u8, p.name, "petId") and p.required) petid_required = true;
    }
    try std.testing.expect(petid_required);

    const put = findOp(spec, "updatePet").?;
    try std.testing.expectEqual(@as(usize, 1), put.params.len);
    try std.testing.expectEqual(doc.ParamLocation.body, put.params[0].location);
    try std.testing.expect(put.params[0].required);
    const sch = put.params[0].schema.object;
    try std.testing.expect(sch.get("properties").?.object.get("category").?.object.get("properties") != null); // $ref expanded
}
