# swagger-mcp

An MCP (Model Context Protocol) server, written in Zig, that turns any
OpenAPI/Swagger spec into tools an agent can call directly.

Point it at an `openapi.json` (file path or URL) via the `load_spec` tool and
every API operation becomes a first-class MCP tool that performs a real HTTP
request and returns the response.

## Features

* One MCP tool per API operation, named after the spec's `operationId`
* Handles both **Swagger 2.0** and **OpenAPI 3.0/3.1** (auto-detected)
* Spec from a local file path or an `http(s)` URL, loaded at runtime — no
  rebuilds, reloads replace the tool list live (`tools/list_changed`)
* Real HTTP execution with path/query/header/form/body parameter mapping
* Bearer-token auth via environment variable
* Works over stdio JSON-RPC; no daemon, no ports

## Requirements

Zig 0.16+ (Homebrew: `brew install zig`).

## Build

```sh
zig build            # -> zig-out/bin/swagger-mcp
zig build test       # unit + integration tests
zig build run -- --spec ./openapi.json
zig build fmt        # format check; `zig fmt .` to fix
zig build fuzz-target  # AFL++ QEMU harness (see fuzz/README.md)
```

## Quick start

```sh
# bare stdio server (spec loaded later via the load_spec tool)
zig-out/bin/swagger-mcp

# preload a spec at startup
zig-out/bin/swagger-mcp --spec ./openapi.json

# preload + pin the API base URL
zig-out/bin/swagger-mcp --spec ./openapi.json --api-base http://api.example.com
```

The server speaks newline-delimited JSON-RPC on stdin/stdout. All diagnostics
go to stderr, so stdout is always a clean protocol channel.

## CLI flags

| Flag | Form | Meaning |
| --- | --- | --- |
| `--spec` | `--spec <path\|url>` or `--spec=<path\|url>` | Load a spec at startup. On failure the server still starts and warns — use `load_spec` manually. |
| `--api-base` | `--api-base <url>` or `--api-base=<url>` | Default API base URL for calls when `load_spec` gets no `api_base` argument. Overridable by the env var below. |

Unknown flags print usage and exit.

## The `load_spec` tool

Always present, even with no spec loaded. Loading a spec replaces the entire
tool list; the client is notified via `notifications/tools/list_changed`
before the call response returns.

```json
{
  "name": "load_spec",
  "arguments": {
    "source": "http://forgejo.example.com/swagger.v1.json",
    "api_base": "http://forgejo.example.com"
  }
}
```

* `source` (required): file path or `http(s)` URL to `openapi.json` /
  `swagger.json`. Specs up to **16 MB** are accepted.
* `api_base` (optional): where to actually send the API calls. The spec's
  `basePath` / server path prefix is re-attached automatically, so
  `api_base: "http://forgejo.example.com"` against a Gitea/Forgejo spec
  correctly hits `http://forgejo.example.com/api/v1/...`.

Up to **2000 operations** per spec; larger specs are rejected.

## How calls work

* Path/query/header/form parameters map from tool arguments
  (`{ "owner": "acme", "page": 3 }`). Values are percent-encoded;
  `collectionFormat: multi` arrays become repeated query params.
* A JSON request body is passed as the `body` argument.
* Required spec parameters appear in the tool's `inputSchema`, so clients can
  validate before calling.
* Base URL precedence (highest first):
  1. `api_base` argument to `load_spec`
  2. `--api-base` flag or `SWAGGER_MCP_API_BASE` env var
  3. the spec's own `host`/`basePath`/`schemes` (Swagger 2.0) or
     `servers[0].url` (OpenAPI 3)
* `Authorization: Bearer $SWAGGER_MCP_TOKEN` is added to every request when
  the env var is set.
* Responses larger than **4 MB** are truncated with a marker. Non-2xx
  responses come back as tool results flagged `isError` (with status + body),
  so the agent can react without the transport failing.

## Configuration reference

| Knob | Where | Effect |
| --- | --- | --- |
| `--spec <path\|url>` | CLI | Preload a spec at startup |
| `--api-base <url>` | CLI | Default API base URL |
| `SWAGGER_MCP_API_BASE` | env | Same as `--api-base` (handy in MCP client config); `api_base` arg to `load_spec` overrides it |
| `SWAGGER_MCP_TOKEN` | env | Adds `Authorization: Bearer <token>` to every call |
| `SWAGGER_MCP_SPEC` | env | Opt-in: `zig build test` additionally parses this real spec (integration smoke test) |

## Wiring into an MCP client (e.g. opencode.json)

```json
{
  "mcp": {
    "forgejo": {
      "type": "local",
      "command": [
        "/path/to/zig-out/bin/swagger-mcp",
        "--spec", "http://forgejo.example.com/swagger.v1.json",
        "--api-base", "http://forgejo.example.com"
      ],
      "environment": {
        "SWAGGER_MCP_TOKEN": "<api token>",
        "SWAGGER_MCP_API_BASE": "http://forgejo.example.com"
      }
    }
  }
}
```

Either way (`--api-base` or the env var) the spec's `basePath` is re-attached
automatically; `load_spec` called without an `api_base` argument uses this
default.

If you leave `--spec` out, connect and then ask the agent to run `load_spec`
with your spec URL/path — useful when the spec URL changes per session.

## Supported spec formats

* **Swagger 2.0** — `$ref` definitions (cycles are cut safely), `formData`,
  `collectionFormat` (csv/ssv/tsv/pipes/multi)
* **OpenAPI 3.0/3.1** — `components`, `requestBody`, server URL templates

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `warning: --spec load failed: ... (use load_spec tool)` at startup | Spec path/URL unreachable or not valid JSON. The server is fine — load the spec later via `load_spec`. |
| Tools return 404 for every call | Base URL missing the spec's path prefix. Pass `--api-base`/`api_base` without the `/api/v1` suffix — the prefix is re-attached automatically. |
| `401 Unauthorized` | `SWAGGER_MCP_TOKEN` not set or the token lacks scope. |
| `TooManyOperations` | Spec has > 2000 operations. |
| Truncated output ending in a marker | Response exceeded 4 MB; narrow the query (pagination, fewer fields). |
| `zig build test` shows only ~2 tests | Expected if modules weren't referenced — check `--summary all`; `src/root.zig` `refAllDecls` should pull in everything (currently ~45 tests, 1 opt-in). |

## Project layout

```
src/
  main.zig        entry point: flag parsing, stdio loop wiring
  rpc.zig         newline-delimited JSON-RPC 2.0 framing
  mcp.zig         MCP protocol: initialize, tools/list, tools/call
  specio.zig      fetch spec bytes from file/URL (16 MB cap)
  openapi/        doc model + Swagger 2.0 / OpenAPI 3.x parsers
  tools.zig       Registry: load_spec + generated tool definitions
  exec.zig        tool args -> HTTP request -> response
  fixtures/       test specs (must live here: @embedFile scope)
  fuzz_target.zig AFL++ harness; fuzz/ = campaign runbook
fuzz/             fuzzing corpus pointer, dictionary, instructions
```

## Status

Experimental. See `AGENTS.md` for internals and the step-by-step history.
