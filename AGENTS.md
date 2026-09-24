# AGENTS.md

## What this repo is

`swagger-mcp`: an MCP server that takes a path/URL to an `openapi.json` spec as input and turns it into a list of commands (one per API operation) the agent can call.

## Experimental target API

- Dogfood target: a self-hosted **Forgejo** instance (host/port configured externally, not in this repo).
- Human page: `<forgejo>/api/swagger` is **Swagger UI HTML, not the spec**.
- Actual spec: `<forgejo>/swagger.v1.json` — **Swagger 2.0** (not OpenAPI 3), ~850 KB, 326 paths, title "Forgejo API 16.0.4+gitea-1.22.0".
- Parser must handle Swagger 2.0, not only OpenAPI 3.x.

## Established decisions

- Transport: **stdio** MCP server (not HTTP/SSE). Spec is loaded at runtime via a `load_spec` tool (dynamic `tools/list` + `list_changed`), not a CLI arg.
- Generated tools make **real HTTP calls** to the target API. Support both **Swagger 2.0 and OpenAPI 3.x**.
- Base URL precedence: `load_spec` arg `api_base` > `--api-base` flag / `SWAGGER_MCP_API_BASE` env (usable in MCP client JSON config) > spec's own host/servers. Both override re-attach the spec `path_prefix`.
- Language: **Zig 0.16** (Homebrew). Workflow per plan step: code + tests + docs, one commit. `zig build test` must pass; run `zig fmt` before committing (`zig build fmt` to check).

## Architecture map

- `src/main.zig` wires it: `tools.Registry` (owns spec lifetimes) -> `mcp.Server` (protocol) -> `rpc.serve` (framing) over stdin/stdout.
- `tools.zig` generates one `mcp.ToolDef` per operation (name = sanitized `operationId`); `exec.zig` maps tool args -> HTTP (path/query/header/form/body), `openapi/` parses specs into `doc.Spec`.
- Test fixtures live in `src/fixtures/`, NOT `tests/` — `@embedFile` cannot reach outside the module path (build fails otherwise).
- `mcp.Server.init` (not struct literal!) — the literal leaves the resp arena undefined => segfault (happened once, step 10).

## Commands

- `zig build` → `zig-out/bin/swagger-mcp`; `zig build test`; `zig build run -- --spec <path|url>`; `zig build fmt`; `zig build fuzz-target` (AFL++ QEMU harness).

## Zig 0.16 gotchas (API differs sharply from pre-0.15 knowledge)

- Entry point is `pub fn main(init: std.process.Init) !void`; use `init.io`, `init.arena.allocator()`, `init.minimal.args.toSlice(arena)`. No `std.process.argsAlloc`.
- New I/O: `std.Io.File.stdin/stdout/stderr()`, `std.Io.File.Reader/Writer.init(file, io, &buf)` with methods on `.interface` (e.g. `takeDelimiterExclusive('\n')`, `print`, `flush`). `std.fs` is paths only; file/dir ops are `std.Io.Dir`/`std.Io.File` and take an `io` param.
- **stdout is the JSON-RPC channel** — all diagnostics must go to stderr (`std.debug.print` writes to stderr and is safe).

- Step 9: memory lifetimes — double-buffered per-load arenas in `Registry` (reload frees the old spec), per-call scratch arenas (`mcp.Server.resp`, `Registry.temp`), 4 MB response truncation marker, `collectionFormat: multi` query support.

- Step 10: README + live dogfood against a self-hosted Forgejo instance: load_spec via URL -> 506 tools, `getVersion` returned real `HTTP 200 {"version":...}`. Found+fixed via dogfooding: `api_base` now re-attaches the spec's `basePath` (Gitea/Forgejo serve from `<api_base>/api/v1`).

## Progress

Workflow: one commit per plan step (code + tests + docs). Per-step summary below (history was squashed to a single commit).

- Step 1: scaffold — `build.zig` (+ `test`/`run`/`fmt` steps), `src/main.zig` (`--spec` parsing), `src/root.zig`.
- Step 2: `src/rpc.zig` — newline-delimited JSON-RPC 2.0 framing/dispatch (parse errors, notifications, id echo).
- Step 3: `src/mcp.zig` — MCP layer: initialize/version negotiation, ping, tools/list, tools/call via `Toolset` interface, `callTestBridge` for integration tests.
- Step 4: `src/specio.zig` — spec bytes from file path or http(s) URL (`std.http.Client.fetch`), 16 MB cap. URL happy-path is covered by the live dogfood (step 10), not a unit test.
- Step 5+6: `src/openapi/` — shared model (`doc.zig`: $ref expand with cycle-cut, tool-name sanitize, dedupe), Swagger 2.0 parser (`swagger2.zig`), OpenAPI 3.x parser (`openapi3.zig`), version dispatch (`parse.zig`); fixtures in `src/fixtures/`. An opt-in test parses a real spec via env `SWAGGER_MCP_SPEC=/path` (verified: Forgejo 850 KB, 506 ops).

- Step 7: `src/tools.zig` — `Registry` (load_spec + generated tools), `notifications/tools/list_changed` written before the tools/call response; stdio loop live in `main.zig`. E2E verified manually: Forgejo spec loads 506 ops + load_spec = 507 tools.
- Step 8: `src/exec.zig` — buildRequest (path/query/header/body, percent-encoding, form data) + execute (std.http.Client, 4 MB response cap, `SWAGGER_MCP_TOKEN` -> `Authorization: Bearer`). Test spins up python3 http.server on an ephemeral port (20000 + pid%20000; skips if no python3; needs a free port in range).

- Fuzz EPIC F1 (AFL++): `tools.fuzzSpec` = crash oracle (empty/dup tool names, schema build) over parse+tool-gen; seeds `src/fuzz_corpus/` (replayed by `zig build test` via `std.testing.fuzz` corpus mode); `src/fuzz_target.zig` + `zig build fuzz-target` = AFL++ QEMU harness; `fuzz/` = dict + campaign runbook (Docker `aflplusplus/aflplusplus`, cross-build `aarch64-linux-musl`). Verified: 90 s smoke run, 208 new corpus items, 0 crashes. Native `zig build test --fuzz` is blocked by a Zig 0.16.0 std bug (test_runner.zig fails to compile with `-ffuzz`).

## Testing quirk (Zig 0.16, critical)

Test blocks in imported files are NOT collected unless forced: `src/root.zig` ends with `test { std.testing.refAllDecls(@This()); }`. Check `zig build test --summary all` shows the expected total (currently 45, 1 skippable opt-in), not just exit 0 — a silent "2 pass" can mean module tests never ran.

## Zig 0.16 std API deltas vs older knowledge

- `std.json.Value/ObjectMap`: ObjectMap is UNMANAGED (`std.array_hash_map.String`): start `var m: json.ObjectMap = .empty;`, insert `m.put(alloc, k, v)`. `json.Array` is Managed: `json.Array.init(alloc)`. Serialize with `json.Stringify{ .writer = w }`.
- `Io.Limit.limited(n)` (no `.atMost`). `std.http.Status` is an enum: compare `res.status != .ok`.
- `Reader.takeDelimiterExclusive` fails with `StreamTooLong` when a line exceeds the reader buffer — `rpc.readLine` works around it via repeated `take`/`peek(1)`; use that helper, never raw takeDelimiterExclusive for framing.
- `File` is `CopyOnWrite`-free value type: reassigning a `var file` after `defer file.close()` double-closes — close explicitly before reopening.
