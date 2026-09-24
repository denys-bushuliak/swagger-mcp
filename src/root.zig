//! Library root: re-exports for tests and tooling.

const std = @import("std");

pub const name = "swagger-mcp";
pub const version = "0.1.0";

pub const rpc = @import("rpc.zig");
pub const mcp = @import("mcp.zig");

pub fn smoke() !void {
    try std.testing.expectEqualStrings("swagger-mcp", name);
}
pub const specio = @import("specio.zig");
pub const openapi = @import("openapi/parse.zig");
pub const tools = @import("tools.zig");
pub const exec = @import("exec.zig");

test {
    std.testing.refAllDecls(@This());
}
