//! swagger-mcp: stdio MCP server exposing OpenAPI/Swagger operations as tools.
//! Protocol traffic goes to stdout only; diagnostics must never use stdout.

const std = @import("std");
const Io = std.Io;
const swaggermcp = @import("swaggermcp");

const Config = struct {
    spec_source: ?[]const u8 = null,
    api_base: ?[]const u8 = null,

    const ParseError = error{BadUsage};

    fn parse(args: []const []const u8) ParseError!Config {
        var cfg = Config{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--spec")) {
                if (i + 1 >= args.len) return ParseError.BadUsage;
                cfg.spec_source = args[i + 1];
                i += 1;
            } else if (std.mem.startsWith(u8, a, "--spec=")) {
                cfg.spec_source = a["--spec=".len..];
            } else if (std.mem.eql(u8, a, "--api-base")) {
                if (i + 1 >= args.len) return ParseError.BadUsage;
                cfg.api_base = args[i + 1];
                i += 1;
            } else if (std.mem.startsWith(u8, a, "--api-base=")) {
                cfg.api_base = a["--api-base=".len..];
            } else {
                return ParseError.BadUsage;
            }
        }
        return cfg;
    }
};

test "Config.parse" {
    const t = std.testing;
    try t.expectEqual(@as(?[]const u8, null), (try Config.parse(&.{})).spec_source);
    try t.expectEqual(@as(?[]const u8, null), (try Config.parse(&.{})).api_base);
    try t.expectEqualStrings("/tmp/a.json", (try Config.parse(&.{ "--spec", "/tmp/a.json" })).spec_source.?);
    try t.expectEqualStrings("http://x/s.json", (try Config.parse(&.{"--spec=http://x/s.json"})).spec_source.?);
    try t.expectEqualStrings("http://api.x", (try Config.parse(&.{ "--api-base", "http://api.x" })).api_base.?);
    try t.expectEqualStrings("http://api.x", (try Config.parse(&.{"--api-base=http://api.x"})).api_base.?);
    var bad = false;
    _ = Config.parse(&.{"--nope"}) catch {
        bad = true;
    };
    try t.expect(bad);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const all_args = try init.minimal.args.toSlice(arena);

    const cfg = Config.parse(all_args[1..]) catch |err| switch (err) {
        error.BadUsage => {
            var buf: [1024]u8 = undefined;
            var fw = Io.File.Writer.init(.stderr(), io, &buf);
            try fw.interface.print("usage: {s} [--spec <path|url>] [--api-base <url>]\n\n{s} v{s} - stdio MCP server\n", .{
                all_args[0], swaggermcp.name, swaggermcp.version,
            });
            try fw.interface.flush();
            std.process.exit(2);
        },
    };

    var registry = try swaggermcp.tools.Registry.init(arena, io);
    const api_base = cfg.api_base orelse swaggermcp.tools.envApiBase(arena);
    registry.default_api_base = api_base;
    if (cfg.spec_source) |source| {
        if (registry.load(source, api_base)) |n| {
            std.debug.print("preloaded {d} operations from {s}\n", .{ n, source });
        } else |err| {
            std.debug.print("warning: --spec load failed: {s} (use load_spec tool)\n", .{@errorName(err)});
        }
    } else {
        std.debug.print("swagger-mcp {s}: call the load_spec tool with a spec path or URL\n", .{swaggermcp.version});
    }

    var server = swaggermcp.mcp.Server.init(arena, registry.toolset());

    const in_buf = try arena.alloc(u8, 1 << 20);
    const out_buf = try arena.alloc(u8, 1 << 20);
    var reader = Io.File.Reader.init(.stdin(), io, in_buf);
    var writer = Io.File.Writer.init(.stdout(), io, out_buf);
    try swaggermcp.rpc.serve(arena, &reader.interface, &writer.interface, swaggermcp.mcp.callTestBridge(&server));
}

test "smoke" {
    try swaggermcp.smoke();
}
