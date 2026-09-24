# swagger-mcp

An MCP (Model Context Protocol) server, written in Zig, that turns any
OpenAPI/Swagger spec into tools an agent can call directly.

Point it at an `openapi.json` (file path or URL) via the `load_spec` tool and
every API operation becomes a first-class MCP tool that performs a real HTTP
request and returns the response.

## Build

Requires Zig 0.16+.

```sh
zig build            # -> zig-out/bin/swagger-mcp
zig build test
zig build fmt        # format check; `zig fmt .` to fix
```

## Use

Start the server (stdio transport):

```sh
zig-out/bin/swagger-mcp
# optionally preload a spec at startup:
zig-out/bin/swagger-mcp --spec ./openapi.json
# and/or set the API base URL used when load_spec gets no api_base argument:
zig-out/bin/swagger-mcp --spec ./openapi.json --api-base http://api.example.com
```

Then either call the `load_spec` tool:

```json
{ "source": "http://forgejo.example.com/swagger.v1.json" }
```

or pass the spec as a path/URL. `load_spec` is always available; loading a
spec replaces the tool list (a `notifications/tools/list_changed` message is
sent before the call response) so the agent sees one tool per API operation,
named after the spec's `operationId`.

### Wiring into an MCP client (e.g. opencode.json)

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

After the client connects, ask the agent to run `load_spec` with your spec
URL/path.

## How calls work

* Path/query/header/form parameters map from tool arguments
  (`{ "owner": "acme", "page": 3 }`).
* A JSON request body is passed as the `body` argument.
* Required spec parameters appear in the tool's `inputSchema`.
* Base URL precedence: `api_base` argument to `load_spec` > `--api-base` /
  `SWAGGER_MCP_API_BASE` > the spec's `host`/`basePath`/`schemes` (Swagger 2.0)
  or `servers[0].url` (OpenAPI 3).
* `Authorization: Bearer $SWAGGER_MCP_TOKEN` is added when the env var is set.
* Responses larger than 4 MB are truncated with a marker. Non-2xx responses
  come back as tool results flagged `isError`.

## Supported spec formats

* Swagger 2.0 (incl. `$ref` definitions, formData, collectionFormat)
* OpenAPI 3.0/3.1 (incl. components, requestBody, server URL templates)

## Status

Experimental. See `AGENTS.md` for internals and the step-by-step history.
