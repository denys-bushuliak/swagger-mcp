//! EPIC F1 fuzz harnesses. Native coverage fuzzer: `zig build test --fuzz`
//! (or `--fuzz=60` for 60s); plain `zig build test` replays the corpus once.

const std = @import("std");
const Smith = std.testing.Smith;
const tools = @import("tools.zig");

const seeds = [_][]const u8{
    @embedFile("fuzz_corpus/seed_min_swagger2.json"),
    @embedFile("fuzz_corpus/seed_min_openapi3.json"),
    @embedFile("fuzz_corpus/seed_refs_cycle.json"),
    @embedFile("fuzz_corpus/seed_formdata.json"),
    @embedFile("fuzz_corpus/seed_dupe_ops.json"),
    @embedFile("fuzz_corpus/seed_deep_nesting.json"),
    @embedFile("fixtures/petstore-swagger2.json"),
    @embedFile("fixtures/petstore-openapi3.json"),
};

/// Bias mutations toward printable JSON syntax, with a floor of raw noise.
const json_weights = [_]Smith.Weight{
    .{ .min = ' ', .max = '~', .weight = 500 },
    .{ .min = '"', .max = '"', .weight = 400 },
    .{ .min = '{', .max = '}', .weight = 300 },
    .{ .min = ':', .max = ',', .weight = 200 },
    .{ .min = 0, .max = 255, .weight = 100 },
};

const max_input = 64 * 1024;

fn checkSpec(_: void, smith: *Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const len: usize = smith.valueRangeLessThan(u17, 1, 64 * 1024);
    const buf = try alloc.alloc(u8, len);
    if (smith.boolWeighted(30, 70)) {
        smith.bytesWeighted(buf, &json_weights);
    } else {
        smith.bytes(buf);
    }
    tools.fuzzSpec(alloc, buf);
}

test "fuzz: spec parse -> tool generation" {
    try std.testing.fuzz({}, checkSpec, .{ .corpus = &seeds });
}

/// Mutation-style fuzz: splice corpus seeds instead of generating from scratch,
/// so deep structures ($ref chains, paths maps) get crossed over.
fn mutate(alloc: std.mem.Allocator, smith: *Smith) ![]const u8 {
    const base = seeds[smith.valueRangeAtMost(u4, 0, seeds.len - 1)];
    const out = try alloc.dupe(u8, base);
    const n_edits: usize = smith.valueRangeLessThan(u6, 1, 32);
    var i: usize = 0;
    while (i < n_edits) : (i += 1) {
        if (out.len == 0) break;
        const at: usize = smith.valueRangeLessThan(u17, 0, @intCast(out.len));
        if (smith.eos()) {
            // byte flip
            out[at] ^= smith.value(u8);
        } else {
            // chunk overwrite from a random seed or json-biased noise
            const other = seeds[smith.valueRangeAtMost(u4, 0, seeds.len - 1)];
            const take = @min(out.len - at, if (smith.boolWeighted(50, 50)) other.len else max_input);
            if (take > 0 and other.len > 0) {
                const src_at: usize = smith.valueRangeLessThan(u17, 0, @intCast(other.len));
                const n = @min(take, other.len - src_at);
                @memcpy(out[at .. at + n], other[src_at .. src_at + n]);
            } else if (take > 0) {
                smith.bytesWeighted(out[at .. at + take], &json_weights);
            }
        }
    }
    return out;
}

fn checkSpecMutated(_: void, smith: *Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    tools.fuzzSpec(arena_state.allocator(), try mutate(arena_state.allocator(), smith));
}

test "fuzz: corpus seed mutation" {
    try std.testing.fuzz({}, checkSpecMutated, .{ .corpus = &seeds });
}
