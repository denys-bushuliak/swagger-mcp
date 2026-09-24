//! Fetches OpenAPI/Swagger spec bytes from a filesystem path or http(s) URL.

const std = @import("std");
const Io = std.Io;

pub const max_size = 16 * 1024 * 1024;

pub const Kind = union(enum) {
    file: []const u8,
    url: []const u8,

    const prefixes = [_][]const u8{ "http://", "https://" };

    pub fn classify(source: []const u8) Kind {
        for (prefixes) |p| {
            if (std.ascii.startsWithIgnoreCase(source, p)) return .{ .url = source };
        }
        return .{ .file = source };
    }
};

pub const LoadError = error{
    SourceTooLarge,
    HttpFailed,
    SourceNotFound,
    BadSource,
} || AllocatorErrs;

const AllocatorErrs = std.mem.Allocator.Error;

/// Returns owned bytes of the spec document; caller frees with `alloc`.
pub fn load(alloc: std.mem.Allocator, io: Io, source: []const u8) LoadError![]u8 {
    return switch (Kind.classify(source)) {
        .file => |path| loadFile(alloc, io, path),
        .url => |url| loadUrl(alloc, io, url),
    };
}

fn loadFile(alloc: std.mem.Allocator, io: Io, path: []const u8) LoadError![]u8 {
    if (path.len == 0) return LoadError.BadSource;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_size)) catch |err|
        switch (err) {
            error.StreamTooLong => return LoadError.SourceTooLarge,
            error.OutOfMemory => return AllocatorErrs.OutOfMemory,
            else => return LoadError.SourceNotFound,
        };
    if (bytes.len > max_size) {
        alloc.free(bytes);
        return LoadError.SourceTooLarge;
    }
    return bytes;
}

fn loadUrl(alloc: std.mem.Allocator, io: Io, url: []const u8) LoadError![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    var buf = Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &buf.writer,
        .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
    }) catch return LoadError.HttpFailed;

    if (res.status != .ok) return LoadError.HttpFailed;
    const data = buf.written();
    if (data.len > max_size) return LoadError.SourceTooLarge;
    return alloc.dupe(u8, data);
}

test "classify" {
    const t = std.testing;
    switch (Kind.classify("http://a/b")) {
        .url => |u| try t.expectEqualStrings("http://a/b", u),
        else => return error.TestUnexpectedResult,
    }
    switch (Kind.classify("HTTPS://A/B")) {
        .url => {},
        else => return error.TestUnexpectedResult,
    }
    switch (Kind.classify("/tmp/openapi.json")) {
        .file => {},
        else => return error.TestUnexpectedResult,
    }
    switch (Kind.classify("openapi.json")) {
        .file => {},
        else => return error.TestUnexpectedResult,
    }
}

test "load from file path" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/swagger-mcp-specio-test.json";
    const payload = "{\"swagger\":\"2.0\"}";
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, payload);

    const got = try load(std.testing.allocator, io, path);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(payload, got);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "load missing file" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        LoadError.SourceNotFound,
        load(std.testing.allocator, io, "/tmp/swagger-mcp-definitely-missing-9f3a2b.json"),
    );
}

test "load url failure surfaces HttpFailed" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Port 1 on loopback: nothing listens; connect must fail, not crash or hang.
    try std.testing.expectError(
        LoadError.HttpFailed,
        load(std.testing.allocator, io, "http://127.0.0.1:1/spec.json"),
    );
}
