# Deploying the ODP connector on MintMCP

This connector gives Claude read access to Optimizely Data Platform (ODP) through ARA's MintMCP gateway. It runs as a MintMCP **hosted connector**: MintMCP runs the Docker image and Claude reaches it through the gateway, so the server itself is never on the public internet.

## Before you start

- **A machine with Docker** that can build `linux/amd64` images. This guide's commands are for a bash shell; on Windows, use Git Bash or WSL.
- **MintMCP admin access**, either through the MintMCP Admin connector in Claude or through app.mintmcp.com.
- **An ODP private API key** from ODP: Settings > APIs. A private key can read every customer record in the ODP account, so handle it like a password: it goes into MintMCP's connector settings, never into this repository or a chat.
- **The account's region:** `us`, `eu` or `au`.

## What ARA changed from the original

| Change | Why |
| --- | --- |
| The image listens on port **8000** (`ENV PORT=8000`) | MintMCP expects MCP at `/mcp` on port 8000. |
| The key and region are also read from `X-MintMCP-Env-ODP_API_KEY` / `X-MintMCP-Env-ODP_REGION` | MintMCP delivers per-user settings as `X-MintMCP-Env-<NAME>` headers. |
| Connector-wide `ODP_API_KEY` / `ODP_REGION` env vars, used when a request brings no key | One key set once by the admin for everyone. |
| No key is no longer an error at connection time | MintMCP checks `initialize` and `tools/list` before anyone has entered a key. Tools that need ODP now fail with a message explaining where to set the key. |

Where a key comes from, highest priority first: the `X-ODP-API-Key` header, then `X-MintMCP-Env-ODP_API_KEY`, then the `ODP_API_KEY` env var. The region follows the same order and falls back to `us`.

## 1. Build and test locally

```bash
docker build --platform linux/amd64 -t mint-odp-mcp:test .
```

```bash
docker run --rm -p 8000:8000 mint-odp-mcp:test
```

In a second terminal, `initialize` must succeed with no key:

```bash
curl -s -X POST http://localhost:8000/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

Expect a JSON-RPC result with `serverInfo` named `odp-mcp`. `tools/list` should also work without a key:

```bash
curl -s -X POST http://localhost:8000/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

## 2. Push the image to MintMCP's registry

1. Check whether a connector already exists. Ask Claude to run `list_gateways` (MintMCP Admin) and look for "ODP". If one exists, use its gateway ID in every step below so the deploy updates it rather than creating a second one.
2. Get push credentials: ask Claude to run `create_registry_push_session`, with the gateway ID if you have one. It returns `imageRef`, `registryHost`, `username`, a short-lived `credentialUrl` and a `finalizeToken`.
3. Build, log in and push. The credential URL pipes the password straight into `docker login`, so the password is never typed or pasted:

```bash
docker build --platform linux/amd64 -t <imageRef> .
```

```bash
curl -fsSL '<credentialUrl>' | docker login <registryHost> -u <username> --password-stdin && docker push <imageRef>
```

## 3. Deploy

Ask Claude to run `deploy_pushed_image` with the `finalizeToken` and this config (for a new connector):

```json
{
  "userGivenName": "Optimizely Data Platform (ODP)",
  "transport": { "type": "http", "path": "/mcp" },
  "envVars": [
    { "name": "ODP_API_KEY", "scope": "global", "value": "REPLACE_ME", "isSecret": true },
    { "name": "ODP_REGION", "scope": "global", "value": "us", "isSecret": false },
    { "name": "ODP_MCP_ALLOW_MUTATIONS", "scope": "global", "value": "false", "isSecret": false },
    { "name": "ODP_MCP_ENABLE_EXPORTS", "scope": "global", "value": "true", "isSecret": false }
  ]
}
```

Then open the connector's settings (`https://app.mintmcp.com/vmcps?id=<gatewayId>&serverTab=settings`) and replace `REPLACE_ME` with the real ODP private key. Enter the key there yourself; never paste it into a chat.

### Choosing the key's scope

- **`global` (as above):** one key, entered once by the admin and used for everyone. This is simplest when only a few people need ODP. Everyone who can use this connector in MintMCP can then read all ODP customer data, so **limit who can access the connector** in MintMCP's access control.
- **`per_user`:** each person enters their own ODP private key in their MintMCP connection settings. Use this if ODP access should follow individual ODP permissions. Change the `ODP_API_KEY` entry's scope to `per_user` and leave its value empty.

`ODP_MCP_ENABLE_EXPORTS=true` keeps the bulk export tools. Exports write files to ODP's own S3 bucket and never change account data. Set it to `false` if you don't want bulk exports.

## 4. Verify

Ask Claude to run these with the gateway ID:

- `get_hosted_connector_status`: the status should be `running`.
- `list_connector_tools`: should list 25 `odp_*` tools, or 23 with exports turned off.
- If anything fails: `query_mcp_logs` (status `error`), then `restart_hosted_connector`.

## 5. Use it from Claude Code

1. In your Claude connector settings, enable the new ODP connector for Claude Code, not just for claude.ai.
2. Start a **new** session. Connectors added after a session starts don't reach it.
3. First check: ask Claude to run `odp_graphql_schema_overview` and `odp_list_objects`. These confirm the key works and show whether ODP holds **events** with page-view data for psca.org. The PSCA dashboard's website-traffic tile depends on this. This server has no dedicated traffic tool, so page-view counts come from `odp_graphql_query` on the events data, or from a data export when there's too much for one query.

## Updating later

Make the change on a branch, then repeat steps 1 to 4 with the existing gateway ID. The deploy then replaces the running image in place.

The original project's GitHub Actions workflow (`.github/workflows/publish-image.yml`) is still here. On every push to `main`, it publishes an image to this repository's GitHub Container Registry (`ghcr.io/american-retirement-association-dev/mint-odp-mcp`). MintMCP doesn't use that image. Delete the workflow if you don't want images published there.
