//! Standalone fuzz harness for AFL++ (QEMU mode on Linux, `afl-fuzz -Q`).
//! Usage: swagger-mcp-fuzz <seed-file>   or   swagger-mcp-fuzz -   (stdin)
//! Non-zero exit / signal on any crash; parse errors are expected and silent.

const std = @import("std");
const Io = std.Io;
const swaggermcp = @import("swaggermcp");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const all_args = try init.minimal.args.toSlice(alloc);
    const source: []const u8 = if (all_args.len > 1) all_args[1] else "-";

    const bytes: []const u8 = if (std.mem.eql(u8, source, "-")) blk: {
        var stdin_reader = Io.File.stdin().reader(io, try alloc.alloc(u8, 1 << 16));
        break :blk stdin_reader.interface.allocRemaining(alloc, .limited(swaggermcp.specio.max_size)) catch {
            std.process.exit(3);
        };
    } else swaggermcp.specio.load(alloc, io, source) catch {
        std.process.exit(3);
    };

    swaggermcp.tools.fuzzSpec(alloc, bytes);
}
